// Stage-2 targeted joint assessment (PRD §13, §12.3, §32.5 steps 6–8).
//
// Everything on this screen is read from the selected joint's protocol, so this
// file has no knowledge of knees, hips or shoulders. That is the whole point of
// the protocol engine (PRD §12.1): a new joint is a new JSON file.
//
// The side is captured here because PRD §13 requires right/left/both, and the
// protocol declares which options a joint supports.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../data/records.dart';
import '../../domain/protocol/models.dart';
import '../../platform/capture/capture.dart';
import '../../pose/pose_types.dart';
import '../../pose/quality_gate.dart';
import '../../pose/synthetic_pose_engine.dart';
import '../../screening/assessment_engine.dart';
import '../../screening/stage1_questionnaire.dart';
import '../widgets/common.dart';

class JointAssessmentScreen extends ConsumerStatefulWidget {
  const JointAssessmentScreen({super.key});

  @override
  ConsumerState<JointAssessmentScreen> createState() =>
      _JointAssessmentScreenState();
}

class _JointAssessmentScreenState extends ConsumerState<JointAssessmentScreen> {
  String? _side;
  final Map<String, TestCapture> _captures = {};
  final Map<String, QualityReport> _quality = {};
  final Set<String> _recording = {};
  bool _running = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(screeningSessionProvider);
    final jointId = session.jointId;

    if (jointId == null) {
      return Scaffold(
        appBar: AppBar(title: Text(context.s('joint.title'))),
        body: const Padding(
          padding: EdgeInsets.all(20),
          child: MessageCard(
            severity: MessageSeverity.error,
            message: 'No joint has been selected for assessment.',
          ),
        ),
      );
    }

    final registryAsync = ref.watch(registryProvider);

    return Scaffold(
      appBar: AppBar(title: Text('${context.s('joint.title')} · $jointId')),
      body: registryAsync.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(error: error),
        data: (registry) {
          final protocol = registry.protocolFor(jointId);
          final side = _side ?? session.jointSide ?? protocol.supportedSides.first;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                title: context.s('joint.side'),
                child: SegmentedButton<String>(
                  segments: [
                    for (final option in protocol.supportedSides)
                      ButtonSegment(
                        value: option,
                        label: Text(_sideLabel(context, option)),
                      ),
                  ],
                  selected: {side},
                  onSelectionChanged: (selection) =>
                      setState(() => _side = selection.first),
                ),
              ),

              SectionCard(
                title: context.s('joint.tests'),
                subtitle: 'Each test is captured separately and gated on its own '
                    'capture quality.',
                child: Column(
                  children: [
                    for (final test in protocol.movementTests)
                      _TestRow(
                        test: test,
                        recorded: _captures.containsKey(test.id),
                        recording: _recording.contains(test.id),
                        quality: _quality[test.id],
                        onRecord: () => _record(protocol, test),
                      ),
                  ],
                ),
              ),

              SectionCard(
                title: context.s('joint.questionnaire'),
                child: protocol.questionnaire.isUsable
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${protocol.questionnaire.instrument} '
                            '${protocol.questionnaire.instrumentVersion} · '
                            '${protocol.questionnaire.items.length} items',
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton(
                            onPressed: () => context.push('/womac'),
                            child: Text(
                              session.questionnaireScore == null
                                  ? 'Answer ${protocol.questionnaire.instrument}'
                                  : 'Edit answers '
                                      '(${session.questionnaireScore!.answered}/'
                                      '${session.questionnaireScore!.itemCount})',
                            ),
                          ),
                        ],
                      )
                    : MessageCard(
                        message: context.s('joint.questionnaire_unavailable'),
                        severity: MessageSeverity.warning,
                      ),
              ),

              if (protocol.wearable.supported)
                SectionCard(
                  title: context.s('joint.wearable'),
                  subtitle: session.jointOutcome?.sensorPlacement == null
                      ? null
                      : 'Recorded placement: '
                          '${session.jointOutcome!.sensorPlacement}',
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/wearable'),
                    icon: const Icon(Icons.sensors),
                    label: const Text('Open Motion Pod'),
                  ),
                ),

              SectionCard(
                title: 'Existing imaging and reports',
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/imaging'),
                  icon: const Icon(Icons.attach_file),
                  label: Text(
                    session.imagingAttached
                        ? 'Imaging attached'
                        : 'Attach existing evidence',
                  ),
                ),
              ),

              if (_error != null)
                MessageCard(message: _error!, severity: MessageSeverity.error),

              const SizedBox(height: 8),
              FilledButton(
                onPressed: _running || !_hasRequiredTests(protocol)
                    ? null
                    : () => _run(protocol, side),
                child: _running
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('RUN ASSESSMENT'),
              ),
              if (!_hasRequiredTests(protocol))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Record every required movement test before running the '
                    'assessment. Optional tests may be skipped.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),

              const SizedBox(height: 24),
              const SafetyBanner(dense: true),
            ],
          );
        },
      ),
    );
  }

  bool _hasRequiredTests(JointProtocol protocol) => protocol.requiredTests
      .every((test) => _captures.containsKey(test.id));

  static String _sideLabel(BuildContext context, String side) => switch (side) {
        'right' => context.s('joint.side.right'),
        'left' => context.s('joint.side.left'),
        'both' => context.s('joint.side.both'),
        _ => side,
      };

  /// Maps a declared test kind onto the synthetic motion used to demonstrate it
  /// when no camera engine is available.
  static SyntheticMotion _motionFor(MovementTestKind kind) => switch (kind) {
        MovementTestKind.activeRom ||
        MovementTestKind.passiveRom ||
        MovementTestKind.reach ||
        MovementTestKind.squat =>
          SyntheticMotion.fixedFlexion,
        MovementTestKind.sitToStand || MovementTestKind.stepDown =>
          SyntheticMotion.sitToStand,
        MovementTestKind.walk => SyntheticMotion.walking,
        MovementTestKind.staticHold || MovementTestKind.balance =>
          SyntheticMotion.standing,
      };

  Future<void> _record(JointProtocol protocol, MovementTest test) async {
    setState(() {
      _recording.add(test.id);
      _error = null;
    });

    PoseCapture? capture;
    StreamSubscription<PoseFrame>? subscription;
    final frames = <PoseFrame>[];

    try {
      // ignore: avoid_print
      print('DBG ${test.id}: create');
      capture = await createPoseCapture(
        topology: ref.read(registryProvider).value!.landmarks,
        motion: _motionFor(test.kind),
        durationSeconds: 8,
      );
      // ignore: avoid_print
      print('DBG ${test.id}: created, start');
      await capture.start();
      // ignore: avoid_print
      print('DBG ${test.id}: started, listen');
      subscription = capture.frames.listen(frames.add);
      // ignore: avoid_print
      print('DBG ${test.id}: listening, delay');

      await Future<void>.delayed(const Duration(seconds: 8));
      // ignore: avoid_print
      print('DBG ${test.id}: delay done, frames=${frames.length}');
      await subscription.cancel();
      // ignore: avoid_print
      print('DBG ${test.id}: cancelled');
      await capture.stop();
      // ignore: avoid_print
      print('DBG ${test.id}: stopped');

      if (frames.isEmpty) {
        setState(() {
          _recording.remove(test.id);
          _error = 'No frames were captured for "${test.nameKey}". Try again.';
        });
        return;
      }

      // The gate runs on the capture, and a failure is recorded rather than
      // discarded: the feature extractor sees the frames either way and the
      // confidence travels into fusion (PRD §15.4).
      final registry = ref.read(registryProvider).value!;
      final gate = QualityGate(
        topology: registry.landmarks,
        config: QualityGateConfig.fromTopology(registry.landmarks),
      );
      final report = gate.evaluate(
        frame: frames.last,
        // Brightness of the frame that was actually on screen. Without this the
        // lighting check could never pass, so every recorded test carried a
        // quality failure it had not earned.
        meanLuma: capture.meanLuma,
        hasCameraImage: capture.meanLuma != null || !capture.isSynthetic,
        recentFrames: frames.length > 8 ? frames.sublist(frames.length - 8) : frames,
        staticCapture: test.kind == MovementTestKind.staticHold,
      );

      setState(() {
        _recording.remove(test.id);
        _quality[test.id] = report;
        _captures[test.id] = TestCapture(
          testId: test.id,
          frames: frames,
          poseEngineId: capture!.engineId,
          poseEngineSynthetic: capture.isSynthetic,
          meanLuma: capture.meanLuma,
          quality: report,
        );
      });
    } catch (error) {
      setState(() {
        _recording.remove(test.id);
        _error = '$error';
      });
    } finally {
      await subscription?.cancel();
      await capture?.stop();
    }
  }

  Future<void> _run(JointProtocol protocol, String side) async {
    setState(() {
      _running = true;
      _error = null;
    });

    try {
      final engine = await ref.read(assessmentEngineProvider.future);
      final repos = await ref.read(repositoriesProvider.future);
      final session = ref.read(screeningSessionProvider);
      final patient = session.patient;

      final answers = session.answers;
      // A staged answer contributes the age and BMI rules; a missing value is
      // skipped by the clinical branch rather than defaulted (see
      // ai/clinical_branch.dart).
      final clinicalInputs = patient == null
          ? const <String, double>{}
          : clinicalInputsFrom(patient);

      final outcome = await engine.run(
        protocol: protocol,
        side: side,
        captures: _captures.values.toList(growable: false),
        clinicalInputs: clinicalInputs,
        questionnaire: session.questionnaireScore,
        // Null when no pod was used, which is a supported configuration: the
        // wearable is optional and comes after Stage 1 (PRD §14).
        imuTrial: session.imuTrial,
        questionnaireConfidence:
            session.questionnaireScore == null ? 0 : (answers?.confidence ?? 0.5),
      );

      final screeningId = session.screening?.screeningId;
      if (screeningId != null) {
        await repos.screenings.saveJoint(
          screeningId: screeningId,
          outcome: outcome,
          questionnaire: session.questionnaireScore,
          instrument: protocol.questionnaire.instrument,
          imagingAvailable: session.imagingAttached,
          actor: ref.read(authProvider)?.workerId,
        );
        await repos.screenings.saveAiResult(
          screeningId: screeningId,
          fusion: outcome.fusion,
          stage1Map: outcome.stage1Map,
          modelVersions: {
            for (final branch in outcome.fusion.allBranches)
              branch.modelId: branch.modelVersion,
          },
        );
        await repos.screenings.updateStatus(
          screeningId,
          ScreeningStatus.jointComplete,
        );
      }

      ref.read(screeningSessionProvider.notifier).setJointOutcome(
            outcome,
            questionnaireScore: session.questionnaireScore,
          );

      if (mounted) context.go('/result');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _running = false;
      });
    }
  }

}

class _TestRow extends StatelessWidget {
  const _TestRow({
    required this.test,
    required this.recorded,
    required this.recording,
    required this.quality,
    required this.onRecord,
  });

  final MovementTest test;
  final bool recorded;
  final bool recording;
  final QualityReport? quality;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = quality != null && !quality!.passed;

    final unverified = quality?.hasUnverifiedChecks ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            recorded
                ? (failed
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline)
                : Icons.radio_button_unchecked,
            color: recorded
                ? (failed
                    ? const Color(0xFFE65100)
                    : (unverified
                        ? const Color(0xFF455A64)
                        : const Color(0xFF1B5E20)))
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${test.nameKey}'
                  '${test.required_ ? ' *' : ' (optional)'}',
                  style: const TextStyle(fontSize: 14.5),
                ),
                if (failed)
                  Text(
                    'Capture quality failed: ${quality!.failures.map((f) => f.detail).join(' ')}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFFE65100)),
                  ),
                if (recorded && !failed)
                  Text(
                    'Recorded · quality ${(quality!.score * 100).round()}%'
                    '${unverified ? ' · ${quality!.notMeasured.map((c) => c.detail).join(' ')}' : ''}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (recording)
            const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              onPressed: onRecord,
              child: Text(
                recorded ? 'Re-record' : context.s('joint.record_test'),
              ),
            ),
        ],
      ),
    );
  }
}
