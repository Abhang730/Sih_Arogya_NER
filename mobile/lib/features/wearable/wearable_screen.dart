// Motion Pod screen (PRD §14, §28 FR-13/FR-14, §32.5 step 7).
//
// PRD §14 is explicit that the wearable is OPTIONAL and comes after Stage 1, so
// this screen is reachable but never on the critical path: leaving it without a
// pod is a supported configuration, and the assessment engine treats a null
// trial as "sensor data absent" rather than as a zero measurement.
//
// Two honesty rules are structural here:
//
//   * The BLE transport is real (lib/platform/pod/pod_native.dart) but the
//     ESP32-S3 firmware does not exist yet, so a real connection will simply not
//     be found in the field today. When the worker chooses the simulated signal
//     instead, that is an explicit, labelled choice — the app never silently
//     substitutes generated data for a paired pod.
//   * The features computed from the trial are shown before they are used, so
//     the worker can see the signal quality that will be attached to the result.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../platform/pod/pod.dart';
import '../../wearable/imu_features.dart';
import '../widgets/common.dart';

class WearableScreen extends ConsumerStatefulWidget {
  const WearableScreen({super.key});

  @override
  ConsumerState<WearableScreen> createState() => _WearableScreenState();
}

class _WearableScreenState extends ConsumerState<WearableScreen> {
  MotionPodSession? _session;
  Timer? _qualityTimer;

  PodConnectionState _state = PodConnectionState.disconnected;
  double _quality = 0;
  bool _busy = false;
  bool _collecting = false;
  String? _error;
  String? _status;

  Map<String, double>? _lastFeatures;

  List<PodPlacement> _placements = const [PodPlacement.thigh, PodPlacement.shin];

  @override
  void dispose() {
    _qualityTimer?.cancel();
    final session = _session;
    if (session != null) {
      // Best-effort teardown: the screen is going away either way, and leaving a
      // GATT connection open would drain the pod.
      unawaited(session.disconnect());
    }
    super.dispose();
  }

  /// Placements the selected joint's protocol intends (PRD §14.3).
  ///
  /// Read from the protocol rather than hard-coded, so a joint whose preferred
  /// rig is different (the ankle, for example) does not silently get the knee's
  /// thigh/shank pair.
  List<PodPlacement> _intendedPlacements() {
    final registry = ref.read(registryProvider).value;
    final jointId = ref.read(screeningSessionProvider).jointId;
    if (registry == null || jointId == null || !registry.hasJoint(jointId)) {
      return const [PodPlacement.thigh, PodPlacement.shin];
    }
    final preferred = registry.protocolFor(jointId).wearable.preferred;
    final placements = <PodPlacement>[];
    for (final pod in preferred?.pods ?? const []) {
      final placement = _placementFor(pod.segment);
      if (placement != null && !placements.contains(placement)) {
        placements.add(placement);
      }
    }
    return placements.isEmpty
        ? const [PodPlacement.thigh, PodPlacement.shin]
        : placements;
  }

  static PodPlacement? _placementFor(String segment) => switch (segment) {
        'thigh' => PodPlacement.thigh,
        'shank' || 'shin' => PodPlacement.shin,
        'lumbar_l5' || 'lumbar' => PodPlacement.lumbar,
        'dorsal_foot' || 'foot' => PodPlacement.foot,
        _ => null,
      };

  /// Connects using the platform's real transport.
  ///
  /// A failure here is surfaced as a failure. It is NOT downgraded to the
  /// simulated session, because a worker who believes they paired a pod and is
  /// actually reading generated data is the exact confusion the PRD forbids.
  Future<void> _connectReal() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });

    final placements = _intendedPlacements();
    MotionPodSession? session;
    try {
      session = await createMotionPodSession(placements: placements);
      await session.connect();
      _adopt(session, placements);
    } catch (error) {
      await session?.disconnect();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _state = PodConnectionState.error;
        _error = '$error';
      });
    }
  }

  /// Uses the generated two-pod gait signal.
  ///
  /// Reachable only by pressing a button that says what it does, and the screen
  /// keeps a non-dismissible notice up for as long as it is in use.
  Future<void> _useSimulated() async {
    final placements = _intendedPlacements();
    setState(() {
      _busy = true;
      _error = null;
    });
    final session = SimulatedMotionPodSession(placements: placements);
    await session.connect();
    _adopt(session, placements);
  }

  void _adopt(MotionPodSession session, List<PodPlacement> placements) {
    _qualityTimer?.cancel();
    _qualityTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) return;
      setState(() => _quality = session.quality);
    });

    setState(() {
      _session = session;
      _placements = placements;
      _state = session.state;
      _quality = session.quality;
      _busy = false;
      _status = session.isSimulated
          ? 'Simulated signal in use — not a measurement of this patient.'
          : 'Connected to ${session.deviceId}.';
    });
  }

  Future<void> _calibrate() async {
    final session = _session;
    if (session == null) return;
    setState(() => _busy = true);
    try {
      await session.calibrate();
      if (mounted) setState(() => _status = 'Calibrated.');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _collect() async {
    final session = _session;
    if (session == null) return;

    setState(() {
      _collecting = true;
      _error = null;
      _status = null;
    });

    try {
      final trial = await session.collect(durationSeconds: 8, sampleRateHz: 50);
      final features = extractImuFeatures(trial);
      ref.read(screeningSessionProvider.notifier).setImuTrial(trial);

      if (!mounted) return;
      setState(() {
        _lastFeatures = features;
        _collecting = false;
        _status = 'Trial recorded (${trial.sampleCount} samples). It will be '
            'used by the next joint assessment.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _collecting = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final session = _session;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('wearable.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (session?.isSimulated ?? false) ...[
            SyntheticDataNotice(message: s.t('wearable.simulated')),
            const SizedBox(height: 10),
          ],

          SectionCard(
            title: s.t('wearable.placement'),
            subtitle: 'Two pods are needed for the proximal-distal coupling the '
                'trained knee model uses. One pod is allowed and reports those '
                'features as absent rather than zero.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final placement in _placements)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.sensors),
                    title: Text(placement.label),
                    subtitle: Text(
                      placement.role == 'proximal' ? 'Proximal' : 'Distal',
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  'Recorded placement is stored with the assessment. The model '
                  'was trained at a different rig, and that difference is '
                  'disclosed on the result (DECISIONS.md D3).',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          SectionCard(
            title: s.t('wearable.connected'),
            trailing: Icon(
              switch (_state) {
                PodConnectionState.connected => Icons.bluetooth_connected,
                PodConnectionState.scanning => Icons.bluetooth_searching,
                PodConnectionState.connecting => Icons.bluetooth_searching,
                PodConnectionState.error => Icons.bluetooth_disabled,
                PodConnectionState.disconnected => Icons.bluetooth,
              },
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  switch (_state) {
                    PodConnectionState.connected => 'Connected',
                    PodConnectionState.scanning => 'Scanning…',
                    PodConnectionState.connecting => 'Connecting…',
                    PodConnectionState.error => 'Connection failed',
                    PodConnectionState.disconnected => s.t('wearable.disconnected'),
                  },
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (session != null && !session.isSimulated)
                  Text(
                    'Device: ${session.deviceId}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                const SizedBox(height: 10),
                MeasurementTile(
                  label: s.t('wearable.live_quality'),
                  value: session == null ? null : _quality * 100,
                  unit: '%',
                  caveat: session == null
                      ? 'Connect a pod to see signal quality.'
                      : (_quality < 0.7
                          ? 'Below the 70% the sensor features need; check the '
                              'pod placement before relying on this trial.'
                          : null),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _busy || _collecting ? null : _connectReal,
                      child: Text(s.t('wearable.scan')),
                    ),
                    if (session == null || session.isSimulated)
                      OutlinedButton(
                        onPressed: _busy || _collecting ? null : _useSimulated,
                        child: const Text('Use simulated signal'),
                      ),
                    if (session != null)
                      OutlinedButton(
                        onPressed: _busy || _collecting ? null : _calibrate,
                        child: Text(s.t('wearable.calibrate')),
                      ),
                  ],
                ),
                if (!hasRealPodTransport)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      podUnavailableReason,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ],
            ),
          ),

          if (_status != null)
            MessageCard(message: _status!, severity: MessageSeverity.success),
          if (_error != null)
            MessageCard(
              message: _error!,
              severity: MessageSeverity.error,
              title: 'Could not use the Motion Pod',
            ),

          SectionCard(
            title: 'Trial',
            subtitle: 'Eight seconds of walking at the protocol sample rate. '
                'Nothing is stored until the trial completes.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.icon(
                  onPressed: session == null || _collecting
                      ? null
                      : (_quality >= 0.7 || session.isSimulated ? _collect : null),
                  icon: const Icon(Icons.fiber_manual_record),
                  label: Text(
                    _collecting ? 'Recording…' : 'Record an 8-second trial',
                  ),
                ),
                if (session != null && _quality < 0.7 && !session.isSimulated)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Signal quality is too low to record. A trial recorded now '
                      'would be stored with a quality failure attached '
                      '(PRD §15.4).',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                if (_collecting) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),

          if (_lastFeatures != null)
            SectionCard(
              title: 'Features this trial produced',
              subtitle: 'These are the values the model will receive. An absent '
                  'feature is absent, never zero.',
              child: Column(
                children: [
                  MeasurementTile(
                    label: 'Acceleration magnitude (mean)',
                    value: _lastFeatures!['imu_acc_magnitude_mean'],
                    unit: 'g',
                  ),
                  MeasurementTile(
                    label: 'Gyroscope magnitude (peak)',
                    value: _lastFeatures!['imu_gyro_magnitude_peak'],
                    unit: '°/s',
                  ),
                  MeasurementTile(
                    label: 'Proximal–distal correlation',
                    value: _lastFeatures!['imu_proximal_distal_correlation'],
                    caveat: _lastFeatures!['imu_proximal_distal_correlation'] == null
                        ? 'Only one pod contributed, so this cannot be measured.'
                        : null,
                  ),
                  MeasurementTile(
                    label: 'Relative phase lag',
                    value: _lastFeatures!['imu_relative_phase_lag'],
                    unit: 'ms',
                  ),
                  MeasurementTile(
                    label: 'Signal quality',
                    value: (_lastFeatures!['imu_signal_quality'] ?? 0) * 100,
                    unit: '%',
                  ),
                ],
              ),
            ),

          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => context.pop(),
            child: Text(s.t('action.save')),
          ),
          const SizedBox(height: 24),
          const SafetyBanner(dense: true),
        ],
      ),
    );
  }
}
