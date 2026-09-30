// Stage-1 whole-body camera screen (PRD §9, §10, §28 FR-07/FR-08/FR-09,
// §32.5 step 4).
//
// Sequence, per PRD §9.2: static posture, then sit-to-stand, then walking. Each
// test is captured separately and gated on its own quality report, because
// merging them into one recording would make a single bad phase silently poison
// every derived feature.
//
// Three rules this screen has to get right:
//
//   * The quality gate is never bypassed (PRD §9.4 "never hide a failed quality
//     check"). The NEXT action stays disabled until the current test passes.
//   * A synthetic engine is called out on screen, not in a log. If this build
//     falls back to generated landmarks, the worker must know before they
//     interpret anything (PRD §1.2).
//   * The engine id is recorded with the assessment, so a stored Stage-1 result
//     always says what produced it (PRD §27.2).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../data/records.dart';
import '../../platform/capture/capture.dart';
import '../../pose/pose_types.dart';
import '../../pose/quality_gate.dart';
import '../../pose/synthetic_pose_engine.dart';
import '../../screening/assessment_engine.dart';
import '../../screening/stage1_questionnaire.dart';
import '../widgets/common.dart';

/// The Stage-1 test sequence (PRD §9.2).
///
/// The ids are the MVP protocol's own camera tests, so the feature pipeline that
/// computes the Stage-1 features is the one declared in protocols/knee/ — the
/// only complete camera pipeline in the repository — rather than a second,
/// parallel implementation that could drift from it.
class Stage1Test {
  const Stage1Test({
    required this.id,
    required this.label,
    required this.instruction,
    required this.motion,
    required this.durationSeconds,
    this.staticCapture = false,
  });

  final String id;
  final String label;
  final String instruction;
  final SyntheticMotion motion;
  final double durationSeconds;
  final bool staticCapture;

  static const List<Stage1Test> sequence = [
    Stage1Test(
      id: 'knee_static_standing',
      label: 'Static posture',
      instruction: 'Ask the patient to stand still and face the camera, feet '
          'shoulder-width apart, arms relaxed.',
      motion: SyntheticMotion.standing,
      durationSeconds: 4,
      staticCapture: true,
    ),
    Stage1Test(
      id: 'knee_sit_to_stand',
      label: 'Sit to stand',
      instruction: 'Ask the patient to stand up from the chair and sit back '
          'down, five times, at their usual pace.',
      motion: SyntheticMotion.sitToStand,
      durationSeconds: 10,
    ),
    Stage1Test(
      id: 'knee_short_walk',
      label: 'Walking',
      instruction: 'Ask the patient to walk away from the camera and back, at '
          'their usual pace.',
      motion: SyntheticMotion.walking,
      durationSeconds: 8,
    ),
  ];
}

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  int _testIndex = 0;

  PoseCapture? _capture;
  StreamSubscription<PoseFrame>? _subscription;

  final List<PoseFrame> _frames = [];

  /// A short rolling buffer of the most recent frames, filled whether or not a
  /// recording is in progress.
  ///
  /// This exists because the stability check needs recent frames, and keeping the
  /// buffer capture-only created a deadlock: capture is gated on stability, and
  /// stability needs frames that only a capture would produce. The buffer is
  /// bounded so a long session cannot grow memory on a low-end device.
  final List<PoseFrame> _recent = [];
  static const int _recentLimit = 12;

  PoseFrame? _latest;
  QualityReport? _quality;

  final Map<String, TestCapture> _captures = {};

  bool _capturing = false;
  bool _working = false;
  String? _error;
  double _progress = 0;

  Stage1Test get _test => Stage1Test.sequence[_testIndex];

  @override
  void initState() {
    super.initState();
    _prepareCapture();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _capture?.stop();
    super.dispose();
  }

  Future<void> _prepareCapture() async {
    try {
      final registry = await ref.read(registryProvider.future);
      final capture = await createPoseCapture(
        topology: registry.landmarks,
        motion: _test.motion,
        durationSeconds: _test.durationSeconds,
      );
      await capture.start();
      if (!mounted) {
        await capture.stop();
        return;
      }
      setState(() {
        _capture = capture;
        _frames.clear();
        _latest = null;
        _quality = null;
      });
      _listen(capture);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  void _listen(PoseCapture capture) {
    _subscription?.cancel();
    _subscription = capture.frames.listen((frame) {
      if (!mounted) return;
      // Only the latest frame is retained for the live overlay; the capture
      // buffer is filled during a recording so memory stays bounded by the test
      // duration rather than by how long the app has been open. The recent-frame
      // buffer, by contrast, is always filled, because the gate needs it before
      // capture is allowed to start.
      _recent.add(frame);
      if (_recent.length > _recentLimit) _recent.removeAt(0);

      setState(() {
        _latest = frame;
        if (_capturing) {
          _frames.add(frame);
          _progress = (_progress + 0.02).clamp(0.0, 1.0);
        }
      });
      _evaluateQuality(frame);
    });
  }

  void _evaluateQuality(PoseFrame frame) {
    final registry = ref.read(registryProvider).value;
    if (registry == null) return;
    final gate = QualityGate(
      topology: registry.landmarks,
      config: QualityGateConfig.fromTopology(registry.landmarks),
    );
    final report = gate.evaluate(
      frame: frame,
      // The measured brightness of the frame that is on screen, so the lighting
      // check runs against real data instead of the null that previously made
      // this check fail unconditionally.
      meanLuma: _capture?.meanLuma,
      hasCameraImage: _capture?.meanLuma != null || !(_capture?.isSynthetic ?? true),
      recentFrames: _recent,
      staticCapture: _test.staticCapture,
    );
    if (mounted) setState(() => _quality = report);
  }

  Future<void> _startCapture() async {
    setState(() {
      _capturing = true;
      _frames.clear();
      _progress = 0;
      _error = null;
    });

    await Future<void>.delayed(
      Duration(milliseconds: (_test.durationSeconds * 1000).round()),
    );
    if (!mounted) return;
    await _stopCapture();
  }

  Future<void> _stopCapture() async {
    final capture = _capture;
    if (capture == null) return;
    setState(() {
      _capturing = false;
      _progress = 1;
    });

    if (_frames.isEmpty) {
      setState(() => _error =
          'No frames were captured. Check the camera and try this test again.');
      return;
    }

    _captures[_test.id] = TestCapture(
      testId: _test.id,
      frames: List<PoseFrame>.from(_frames),
      poseEngineId: capture.engineId,
      poseEngineSynthetic: capture.isSynthetic,
      meanLuma: capture.meanLuma,
      quality: _quality,
    );
  }

  Future<void> _nextTest() async {
    if (_testIndex < Stage1Test.sequence.length - 1) {
      await _capture?.stop();
      _subscription?.cancel();
      setState(() {
        _testIndex++;
        _progress = 0;
      });
      await _prepareCapture();
      return;
    }
    await _finishStage1();
  }

  Future<void> _finishStage1() async {
    setState(() {
      _working = true;
      _error = null;
    });

    try {
      final registry = await ref.read(registryProvider.future);
      final engine = await ref.read(assessmentEngineProvider.future);
      final repos = await ref.read(repositoriesProvider.future);

      // Stage 1 feeds every joint's locator from the MVP protocol's camera
      // pipeline, because that is the only complete camera feature pipeline
      // declared in the protocol set.
      final stage1Protocol = registry.protocolFor('knee');

      final stage1 = await engine.run(
        protocol: stage1Protocol,
        side: 'both',
        captures: _captures.values.toList(growable: false),
      );

      final session = ref.read(screeningSessionProvider);
      final answers = session.answers;

      // The engine already ran the Stage-1 localiser with exactly this
      // assessment's evidence, so its map is used directly. Re-running it here
      // would risk the stored Stage-1 result and the joint result disagreeing.
      final riskMap = stage1.stage1Map;
      if (riskMap == null) {
        throw StateError(
          'Stage 1 produced no joint risk map, so no body map can be shown.',
        );
      }

      final engineIds = _captures.values.map((c) => c.poseEngineId).toSet();
      final synthetic = _captures.values.any((c) => c.poseEngineSynthetic);

      final screeningId = session.screening?.screeningId;
      if (screeningId != null) {
        await repos.screenings.saveStage1(
          screeningId: screeningId,
          answers: answers ?? Stage1Answers(),
          riskMap: riskMap,
          poseEngineId: engineIds.join(', '),
          poseEngineSynthetic: synthetic,
          poseFeatures: {
            for (final entry in stage1.features.entries) entry.key: entry.value,
          },
          quality: _quality?.toJson(),
          actor: ref.read(authProvider)?.workerId,
        );
        await repos.screenings.updateStatus(
          screeningId,
          ScreeningStatus.stage1Complete,
        );
      }

      ref.read(screeningSessionProvider.notifier).setStage1(
            riskMap: riskMap,
            poseEngineId: engineIds.join(', '),
            synthetic: synthetic,
          );

      if (mounted) context.go('/risk-map');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _working = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final quality = _quality;
    final passed = quality?.passed ?? false;
    final isLast = _testIndex == Stage1Test.sequence.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('camera.title')),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 6),
              child: Text(
                'Test ${_testIndex + 1} of ${Stage1Test.sequence.length} · '
                '${_test.label}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_capture?.isSynthetic ?? false) ...[
            SyntheticDataNotice(message: s.t('camera.synthetic_warning')),
            const SizedBox(height: 10),
          ],

          // Live view with the landmark overlay.
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_capture != null)
                    _capture!.buildPreview(context)
                  else
                    const ColoredBox(color: Color(0xFF1A1A1A)),
                  if (_latest != null)
                    CustomPaint(
                      painter: _PosePainter(frame: _latest!),
                    ),
                  if (_capturing)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: LinearProgressIndicator(value: _progress),
                      ),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 14),
          SectionCard(
            title: s.t('camera.setup_title'),
            child: Text(
              _test.instruction,
              style: const TextStyle(fontSize: 14.5, height: 1.4),
            ),
          ),

          SectionCard(
            title: s.t('camera.quality_title'),
            subtitle: passed
                ? null
                : s.t('camera.quality_blocked'),
            child: quality == null
                ? const Text('Waiting for the first frame…')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final check in quality.checks)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                switch (check.result) {
                                  QualityCheckResult.passed =>
                                    Icons.check_circle_outline,
                                  QualityCheckResult.failed => Icons.cancel_outlined,
                                  // A distinct icon and colour, because "not
                                  // checked" must not look like either outcome.
                                  QualityCheckResult.notMeasured =>
                                    Icons.remove_circle_outline,
                                },
                                size: 18,
                                color: switch (check.result) {
                                  QualityCheckResult.passed =>
                                    const Color(0xFF1B5E20),
                                  QualityCheckResult.failed =>
                                    const Color(0xFFB71C1C),
                                  QualityCheckResult.notMeasured =>
                                    const Color(0xFF455A64),
                                },
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${_checkLabel(check.id)}'
                                      '${check.notMeasured ? ' · not measured' : ''}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13.5,
                                      ),
                                    ),
                                    Text(
                                      check.detail,
                                      style: const TextStyle(fontSize: 12.5, height: 1.3),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (quality.failures.isNotEmpty)
                        const SizedBox(height: 8),
                    ],
                  ),
          ),

          if (_error != null)
            MessageCard(message: _error!, severity: MessageSeverity.error),

          const SizedBox(height: 6),
          if (!_capturing)
            FilledButton.icon(
              // The gate is a precondition, not a warning. PRD §9.4.
              onPressed: passed && !_working ? _startCapture : null,
              icon: const Icon(Icons.videocam),
              label: Text(
                _captures.containsKey(_test.id)
                    ? 'Re-record ${_test.label}'
                    : s.t('camera.start'),
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: _stopCapture,
              icon: const Icon(Icons.stop),
              label: Text(s.t('camera.stop')),
            ),

          const SizedBox(height: 10),
          FilledButton(
            onPressed: (_captures.containsKey(_test.id) && !_working && !_capturing)
                ? _nextTest
                : null,
            child: _working
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(isLast ? 'BUILD BODY MAP' : s.t('action.next')),
          ),

          const SizedBox(height: 24),
          const SafetyBanner(dense: true),
        ],
      ),
    );
  }

  static String _checkLabel(QualityCheckId id) => switch (id) {
        QualityCheckId.landmarkVisibility => 'Body detected',
        QualityCheckId.poseConfidence => 'Pose confidence',
        QualityCheckId.fullBodyInFrame => 'Full body in frame',
        QualityCheckId.lighting => 'Lighting',
        QualityCheckId.stability => 'Held steady',
      };
}

/// Draws the 33-landmark skeleton over the preview.
///
/// Landmarks arrive normalised to the source image; they are mapped linearly
/// onto the preview box. That is exact when the preview and the source share an
/// aspect ratio (the synthetic path) and approximate otherwise. It is a visual
/// aid only — no measurement is taken from this painter, so an imperfect overlay
/// cannot corrupt a result. Making it exact needs the preview's aspect
/// correction, which is part of the device benchmark the PRD calls for.
class _PosePainter extends CustomPainter {
  const _PosePainter({required this.frame});

  final PoseFrame frame;

  /// Landmark index pairs that form the skeleton. Face and hand landmarks are
  /// deliberately omitted: this product never measures them.
  static const List<List<String>> _bones = [
    ['left_shoulder', 'right_shoulder'],
    ['left_shoulder', 'left_elbow'],
    ['left_elbow', 'left_wrist'],
    ['right_shoulder', 'right_elbow'],
    ['right_elbow', 'right_wrist'],
    ['left_shoulder', 'left_hip'],
    ['right_shoulder', 'right_hip'],
    ['left_hip', 'right_hip'],
    ['left_hip', 'left_knee'],
    ['left_knee', 'left_ankle'],
    ['left_ankle', 'left_heel'],
    ['left_heel', 'left_foot_index'],
    ['right_hip', 'right_knee'],
    ['right_knee', 'right_ankle'],
    ['right_ankle', 'right_heel'],
    ['right_heel', 'right_foot_index'],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final byKey = <String, PoseLandmark>{
      for (final landmark in frame.landmarks) landmark.key: landmark,
    };

    final bonePaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final jointPaint = Paint()..color = const Color(0xFFFFEA00);

    Offset? positionOf(String key) {
      final landmark = byKey[key];
      if (landmark == null || landmark.likelihood < 0.3) return null;
      return Offset(landmark.x * size.width, landmark.y * size.height);
    }

    for (final bone in _bones) {
      final a = positionOf(bone[0]);
      final b = positionOf(bone[1]);
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, bonePaint);
    }

    for (final landmark in frame.landmarks) {
      if (landmark.likelihood < 0.3) continue;
      canvas.drawCircle(
        Offset(landmark.x * size.width, landmark.y * size.height),
        3.5,
        jointPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_PosePainter oldDelegate) =>
      oldDelegate.frame != frame;
}
