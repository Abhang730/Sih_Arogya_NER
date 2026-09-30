// Native Motion Pod transport (PRD §14, §28 FR-13/FR-14).
//
// The ESP32-S3 firmware does not exist yet (README implementation status), so
// the packet format below is the CONTRACT the firmware must implement rather
// than a description of something observed. It is written down here, in code,
// because a documented wire format is the part of a hardware integration that
// has to be agreed before either side can be built:
//
//   Service  : 6f3a0001-6d6f-7469-6f6e-706f64000001
//   Notify   : 6f3a0002-6d6f-7469-6f6e-706f64000001  (sample stream)
//   Control  : 6f3a0003-6d6f-7469-6f6e-706f64000001  (start/stop/calibrate)
//
//   Notify payload: N x 12 bytes, little-endian int16, per sample:
//     ax, ay, az  (milli-g, so /1000 for g)
//     gx, gy, gz  (deci-deg/s, so /10 for deg/s)
//
//   Control payload: 1 byte — 0x01 start, 0x02 stop, 0x03 calibrate.
//
// Because the other side of this contract does not exist, NOTHING here has been
// verified against real hardware, and this file says so rather than implying a
// working integration. The app never silently substitutes the simulated signal
// for a real pod: [BleMotionPodSession.connect] failing surfaces as a connection
// error, and the wearable screen requires an explicit choice to use the
// simulated signal instead.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../wearable/imu_features.dart';
import 'pod_types.dart';

/// Whether real Motion Pod hardware can be reached on this platform. BLE is
/// Android/iOS only; the Windows and web targets have no transport.
bool get hasRealPodTransport => Platform.isAndroid || Platform.isIOS;

String get podUnavailableReason =>
    'BLE is unavailable on ${Platform.operatingSystem}. The Motion Pod '
    'connects over Bluetooth from an Android or iOS device.';

Future<MotionPodSession> createMotionPodSession({
  required List<PodPlacement> placements,
}) async {
  if (hasRealPodTransport) return BleMotionPodSession(placements: placements);
  return SimulatedMotionPodSession(placements: placements);
}

/// UUIDs the firmware must advertise. See the contract at the top of this file.
class MotionPodUuids {
  const MotionPodUuids._();

  static final Guid service = Guid('6f3a0001-6d6f-7469-6f6e-706f64000001');
  static final Guid sampleStream = Guid('6f3a0002-6d6f-7469-6f6e-706f64000001');
  static final Guid control = Guid('6f3a0003-6d6f-7469-6f6e-706f64000001');

  static const int cmdStart = 0x01;
  static const int cmdStop = 0x02;
  static const int cmdCalibrate = 0x03;
}

/// Real BLE session against the Arogya Motion Pod.
///
/// UNVERIFIED against hardware: the ESP32-S3 firmware is not built yet, so this
/// has only been exercised up to the point where a device would have to answer.
class BleMotionPodSession implements MotionPodSession {
  BleMotionPodSession({required this.placements});

  @override
  final List<PodPlacement> placements;

  @override
  String get deviceId => _device?.remoteId.toString() ?? 'unpaired';

  @override
  bool get isSimulated => false;

  @override
  PodConnectionState get state => _state;
  PodConnectionState _state = PodConnectionState.disconnected;

  @override
  double get quality => _quality;
  double _quality = 0;

  BluetoothDevice? _device;
  final Map<PodPlacement, StreamController<MotionPodReading>> _controllers = {};
  final Map<PodPlacement, StreamSubscription<List<int>>> _notifySubscriptions = {};
  final Map<PodPlacement, BluetoothCharacteristic> _controlCharacteristics = {};

  /// Rolling window of recent samples per placement, used for the live quality
  /// figure. Bounded, because the live indicator must not grow memory over a
  /// long session.
  final Map<PodPlacement, List<ImuSample>> _windows = {};

  static const int _maxWindowSamples = 150;

  @override
  Stream<MotionPodReading> readings(PodPlacement placement) {
    final controller = _controllers[placement];
    if (controller == null) {
      throw ArgumentError(
        'This session is not capturing ${placement.label}.',
      );
    }
    return controller.stream;
  }

  @override
  Future<void> connect() async {
    _state = PodConnectionState.scanning;
    for (final placement in placements) {
      _controllers[placement] ??= StreamController<MotionPodReading>.broadcast();
      _windows[placement] = <ImuSample>[];
    }

    try {
      if (!await FlutterBluePlus.isSupported) {
        throw StateError('Bluetooth is not supported on this device.');
      }

      // One pod per placement is not yet modelled on the wire: the current
      // contract exposes a single sample stream, so a dual-pod capture needs
      // two physical devices and the app distinguishes them by connection
      // order. The firmware phase has to resolve this; it is recorded in
      // docs/DECISIONS.md rather than left implicit here.
      final results = await _scanForPod();
      if (results.isEmpty) {
        throw StateError(
          'No Arogya Motion Pod was found. Check that the pod is powered on and '
          'within range.',
        );
      }

      _state = PodConnectionState.connecting;
      final device = results.first.device;
      // flutter_blue_plus 2.x requires an explicit licence declaration.
      // License.nonprofit covers personal, nonprofit and educational use; it is
      // correct for this project (SIH 2026, no commercial deployment) but MUST
      // be re-confirmed against a commercial licence before any paid rollout.
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      _device = device;

      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == MotionPodUuids.service,
        orElse: () => throw StateError(
          'The device responded, but it does not expose the Motion Pod service. '
          'It may not be an Arogya Motion Pod.',
        ),
      );

      final stream = service.characteristics.firstWhere(
        (c) => c.uuid == MotionPodUuids.sampleStream,
      );
      final control = service.characteristics.firstWhere(
        (c) => c.uuid == MotionPodUuids.control,
      );

      await stream.setNotifyValue(true);

      // The single stream feeds every configured placement in the current
      // contract. Recorded explicitly so the limitation is visible.
      for (final placement in placements) {
        _controlCharacteristics[placement] = control;
        _notifySubscriptions[placement] = stream.onValueReceived.listen(
          (data) => _onPacket(placement, data),
        );
      }

      await control.write([MotionPodUuids.cmdStart]);
      _state = PodConnectionState.connected;
    } on Object {
      _state = PodConnectionState.error;
      rethrow;
    }
  }

  Future<List<ScanResult>> _scanForPod() async {
    final found = <ScanResult>[];
    final completer = Completer<void>();

    final subscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        if (result.device.platformName.isEmpty) continue;
        if (result.advertisementData.serviceUuids
            .contains(MotionPodUuids.service)) {
          found.add(result);
          if (!completer.isCompleted) completer.complete();
        }
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [MotionPodUuids.service],
      timeout: const Duration(seconds: 12),
    );

    await completer.future.timeout(
      const Duration(seconds: 13),
      onTimeout: () {},
    );
    await FlutterBluePlus.stopScan();
    await subscription.cancel();

    return found;
  }

  /// Decodes one notify packet: N consecutive 12-byte little-endian samples.
  void _onPacket(PodPlacement placement, List<int> data) {
    const sampleBytes = 12;
    if (data.length < sampleBytes) return;

    final controller = _controllers[placement];
    if (controller == null || controller.isClosed) return;

    final bytes = Uint8List.fromList(data);
    final view = ByteData.sublistView(bytes);
    final now = DateTime.now().microsecondsSinceEpoch;

    for (var offset = 0; offset + sampleBytes <= bytes.length; offset += sampleBytes) {
      final sample = <double>[
        view.getInt16(offset, Endian.little) / 1000.0,
        view.getInt16(offset + 2, Endian.little) / 1000.0,
        view.getInt16(offset + 4, Endian.little) / 1000.0,
        view.getInt16(offset + 6, Endian.little) / 10.0,
        view.getInt16(offset + 8, Endian.little) / 10.0,
        view.getInt16(offset + 10, Endian.little) / 10.0,
      ];

      controller.add(MotionPodReading(
        timestampUs: now + offset ~/ sampleBytes,
        placement: placement,
        sample: sample,
      ));

      final window = _windows[placement]!;
      window.add(sample);
      if (window.length > _maxWindowSamples) window.removeAt(0);
      _quality = signalQuality(window);
    }
  }

  @override
  Future<void> calibrate() async {
    for (final characteristic in _controlCharacteristics.values) {
      await characteristic.write([MotionPodUuids.cmdCalibrate]);
    }
  }

  @override
  Future<ImuTrial> collect({
    required double durationSeconds,
    double sampleRateHz = 50,
  }) async {
    // The pod's own sample rate is what it is; [sampleRateHz] is the rate the
    // caller expects the model was trained at, and it is recorded on the trial
    // so the feature extractor's lag conversion stays correct either way.
    final samples = <PodPlacement, List<ImuSample>>{
      for (final placement in placements) placement: <ImuSample>[],
    };

    final subscriptions = <StreamSubscription<MotionPodReading>>[
      for (final placement in placements)
        readings(placement).listen((r) => samples[placement]!.add(r.imuSample)),
    ];

    await Future<void>.delayed(
      Duration(milliseconds: (durationSeconds * 1000).round()),
    );
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }

    List<ImuSample>? forRole(String role) {
      for (final entry in samples.entries) {
        if (entry.key.role == role) return entry.value;
      }
      return null;
    }

    return ImuTrial(
      sampleRateHz: sampleRateHz,
      proximal: forRole('proximal'),
      distal: forRole('distal'),
    );
  }

  @override
  Future<void> disconnect() async {
    final control = _controlCharacteristics.values.firstOrNull;
    if (control != null) {
      try {
        await control.write([MotionPodUuids.cmdStop]);
      } catch (_) {
        // The pod may already be gone; tearing down locally is still correct.
      }
    }

    for (final subscription in _notifySubscriptions.values) {
      await subscription.cancel();
    }
    _notifySubscriptions.clear();
    _controlCharacteristics.clear();

    try {
      await _device?.disconnect();
    } catch (_) {
      // Ignore: the goal is a disconnected state, not a successful goodbye.
    }
    _device = null;

    for (final controller in _controllers.values) {
      if (!controller.isClosed) await controller.close();
    }
    _controllers.clear();
    _state = PodConnectionState.disconnected;
  }
}
