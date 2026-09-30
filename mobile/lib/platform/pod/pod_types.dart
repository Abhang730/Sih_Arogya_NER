// Arogya Motion Pod boundary (PRD §14, §15, §28 FR-13/FR-14).
//
// PRD §14.3 specifies a dual pod on thigh + shin for the knee. The IMU features
// the trained models expect (imu_proximal_distal_correlation,
// imu_relative_phase_lag) need BOTH pods, so the session API is built around two
// placements rather than one device — a single-pod capture is representable and
// reports the relative-motion features as ABSENT, which is what
// lib/wearable/imu_features.dart already does for a single-pod trial.
//
// The simulated session below exists because the ESP32-S3 firmware is not built
// yet (README: "Motion Pod firmware — Not built yet"). It produces a
// biomechanically plausible two-pod gait signal so the feature extractor and the
// trained model can be exercised end to end. It is NOT a stand-in presented as
// hardware: [isSimulated] is true, the placement it reports is explicit, and the
// wearable screen renders a non-dismissible notice while it is in use.

import 'dart:async';
import 'dart:math' as math;

import '../../wearable/imu_features.dart';

/// Where a pod is worn.
///
/// [proximal] and [distal] are the roles the feature extractor needs;
/// [description] is the physical placement, which matters because DECISIONS.md
/// D3 requires the app to disclose when the training placement differs from the
/// protocol's intended one.
enum PodPlacement {
  thigh('proximal', 'Thigh', 'thigh'),
  shin('distal', 'Shin', 'shin'),
  lumbar('proximal', 'Lower back (L5)', 'lumbar_l5'),
  foot('distal', 'Dorsal foot', 'dorsal_foot');

  const PodPlacement(this.role, this.label, this.wire);

  /// 'proximal' or 'distal'.
  final String role;
  final String label;
  final String wire;

  static PodPlacement byRole(String role) =>
      PodPlacement.values.firstWhere((p) => p.role == role);
}

/// One six-axis sample from a pod.
class MotionPodReading {
  const MotionPodReading({
    required this.timestampUs,
    required this.placement,
    required this.sample,
  });

  final int timestampUs;
  final PodPlacement placement;

  /// `[ax, ay, az, gx, gy, gz]` — acceleration in g, angular velocity in deg/s,
  /// matching [ImuSample] exactly so readings feed the feature extractor with no
  /// conversion step in between.
  final List<double> sample;

  ImuSample get imuSample => sample;
}

/// Connection state, surfaced to the worker rather than only logged.
enum PodConnectionState {
  disconnected('disconnected'),
  scanning('scanning'),
  connecting('connecting'),
  connected('connected'),
  error('error');

  const PodConnectionState(this.wire);

  final String wire;
}

/// A session with one or two Motion Pods.
abstract class MotionPodSession {
  /// Stable identifier recorded with the assessment. For a simulated session
  /// this is deliberately not a MAC address, so it can never be mistaken for a
  /// real device in the database.
  String get deviceId;

  /// True when readings are generated. Callers MUST surface this.
  bool get isSimulated;

  /// Which placements this session is capturing.
  List<PodPlacement> get placements;

  PodConnectionState get state;

  /// Live readings from one placement.
  Stream<MotionPodReading> readings(PodPlacement placement);

  /// Latest signal quality in 0..1, from [signalQuality] over a moving window.
  double get quality;

  Future<void> connect();
  Future<void> calibrate();
  Future<void> disconnect();

  /// Collects a fixed-duration trial, suitable for [extractImuFeatures].
  ///
  /// [durationSeconds] is bounded because a field screening is a few seconds,
  /// not an open-ended recording, and an unbounded buffer is a memory risk on a
  /// low-end phone.
  Future<ImuTrial> collect({
    required double durationSeconds,
    double sampleRateHz = 50,
  });
}

/// Simulated dual-pod session.
///
/// Generates a walking-like gait signal: a fundamental stride frequency with a
/// second harmonic, plus a small phase lag between the thigh and shin pods. The
/// lag is not decoration — without it
/// [extractImuFeatures] would report zero proximal-distal coupling, and a model
/// fed that would be scored on a signal no real gait ever produces.
class SimulatedMotionPodSession implements MotionPodSession {
  SimulatedMotionPodSession({
    this.placements = const [PodPlacement.thigh, PodPlacement.shin],
    this.seed = 11,
    this.strideHz = 0.9,
  });

  @override
  final List<PodPlacement> placements;

  final int seed;

  /// Stride frequency in Hz for the simulated walker.
  final double strideHz;

  @override
  String get deviceId => 'simulated-pod';

  @override
  bool get isSimulated => true;

  @override
  PodConnectionState get state => _state;
  PodConnectionState _state = PodConnectionState.disconnected;

  @override
  double get quality => _quality;
  double _quality = 0;

  final Map<PodPlacement, StreamController<MotionPodReading>> _controllers = {};
  final Map<PodPlacement, Timer> _timers = {};

  /// A fixed offset between the pods, in seconds. ~40 ms is in the range a real
  /// shank lags a thigh during stance.
  static const double _phaseLagSeconds = 0.040;

  @override
  Stream<MotionPodReading> readings(PodPlacement placement) {
    final controller = _controllers[placement];
    if (controller == null) {
      throw ArgumentError(
        'This session is not capturing ${placement.label}. '
        'Configured placements: ${placements.map((p) => p.label).join(', ')}.',
      );
    }
    return controller.stream;
  }

  @override
  Future<void> connect() async {
    _state = PodConnectionState.connecting;
    for (final placement in placements) {
      _controllers[placement] ??= StreamController<MotionPodReading>.broadcast();
    }
    // A short delay so the UI's connection state is exercised rather than
    // skipped instantly, which is how a real BLE pairing behaves.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    _state = PodConnectionState.connected;
  }

  @override
  Future<void> calibrate() async {
    // Calibration on real hardware establishes the gravity reference. The
    // simulated signal already has a stable gravity component, so this is a
    // no-op that still returns the same Future shape a real calibration does.
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  /// Starts emitting readings in real time at [sampleRateHz].
  void startStreaming({double sampleRateHz = 50}) {
    final interval = Duration(microseconds: (1000000 / sampleRateHz).round());
    final start = DateTime.now();

    for (final placement in placements) {
      final controller = _controllers[placement];
      if (controller == null) continue;
      _timers[placement]?.cancel();
      _timers[placement] = Timer.periodic(interval, (_) {
        if (controller.isClosed) return;
        final now = DateTime.now();
        final t = now.difference(start).inMicroseconds / 1000000.0;
        final reading = MotionPodReading(
          timestampUs: now.microsecondsSinceEpoch,
          placement: placement,
          sample: _sampleFor(placement, t),
        );
        controller.add(reading);
        _quality = signalQuality([reading.sample]);
      });
    }
  }

  List<double> _sampleFor(PodPlacement placement, double t) {
    final lag = placement == PodPlacement.shin ? _phaseLagSeconds : 0.0;
    final phase = 2 * math.pi * strideHz * (t - lag);

    // Gravity plus a gait-shaped acceleration trace. Magnitudes stay inside the
    // 0.2..8 g validity band so signalQuality reflects a good capture rather
    // than a dropout.
    final ax = 0.28 * math.sin(phase) + 0.06 * math.sin(2 * phase);
    final ay = 0.22 * math.cos(phase);
    final az = 1.0 + 0.35 * math.sin(phase + 0.6) + 0.10 * math.cos(2 * phase);

    // Angular velocity rises sharply through swing, which is the shape the
    // gyro-derived features are built to notice.
    final swing = math.max(0.0, math.sin(phase));
    final gx = 55 * swing * math.sin(phase);
    final gy = 18 * math.cos(phase);
    final gz = 12 * swing;

    final noise = _noise(placement, t);
    return [
      ax + noise[0],
      ay + noise[1],
      az + noise[2],
      gx + noise[3],
      gy + noise[4],
      gz + noise[5],
    ];
  }

  /// Deterministic low-amplitude noise, so a repeated run produces the same
  /// trial and a test can assert on it.
  List<double> _noise(PodPlacement placement, double t) {
    final base = placement.index * 7 + seed;
    double n(int i) =>
        math.sin((t * 37.0 + base + i * 1.7)) * 0.008 +
        math.cos((t * 91.0 + base + i * 2.3)) * 0.004;
    return [n(0), n(1), n(2), n(3), n(4), n(5)];
  }

  @override
  Future<ImuTrial> collect({
    required double durationSeconds,
    double sampleRateHz = 50,
  }) async {
    final samples = <PodPlacement, List<ImuSample>>{
      for (final placement in placements) placement: <ImuSample>[],
    };

    final subscriptions = <StreamSubscription<MotionPodReading>>[];
    final done = Completer<void>();

    for (final placement in placements) {
      subscriptions.add(readings(placement).listen((reading) {
        samples[placement]!.add(reading.imuSample);
      }));
    }

    startStreaming(sampleRateHz: sampleRateHz);
    await Future<void>.delayed(
      Duration(milliseconds: (durationSeconds * 1000).round()),
    );
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    if (!done.isCompleted) done.complete();

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
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final controller in _controllers.values) {
      if (!controller.isClosed) await controller.close();
    }
    _controllers.clear();
    _state = PodConnectionState.disconnected;
  }
}
