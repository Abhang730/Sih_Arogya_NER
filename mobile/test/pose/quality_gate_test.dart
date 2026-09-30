// Capture quality gate tests (PRD §9.4, §19.2, §26.5).
//
// These exist because the gate had a deadlock and a permanently-failing check,
// and neither was visible from the code alone:
//
//   1. The lighting check failed whenever [meanLuma] was null, which was ALWAYS
//      the case because no caller passed it. A capture could never start.
//   2. The stability check needed three recent frames, but frames were only
//      buffered while capturing — and capturing was gated on stability. So a
//      static test could never begin either.
//
// Both are the same underlying mistake: treating "could not measure this" as
// "this failed". The gate now has a third outcome, and these tests pin it down,
// including the demonstration path (synthetic landmarks) end to end.

import 'package:arogya_ner/domain/protocol/registry.dart';
import 'package:arogya_ner/pose/pose_types.dart';
import 'package:arogya_ner/pose/quality_gate.dart';
import 'package:arogya_ner/pose/synthetic_pose_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProtocolRegistry registry;
  late QualityGate gate;

  setUpAll(() async {
    registry = await ProtocolRegistry.load();
    gate = QualityGate(
      topology: registry.landmarks,
      config: QualityGateConfig.fromTopology(registry.landmarks),
    );
  });

  /// A frame the gate should accept: the synthetic figure, framed as a real
  /// patient is expected to be framed.
  PoseFrame framedFrame({double t = 0}) => SyntheticPoseFactory(
        topology: registry.landmarks,
        limb: SyntheticPoseFactory.fullBodyLimb,
      ).frame(motion: SyntheticMotion.standing, t: t);

  group('a check that cannot be measured does not block a capture', () {
    test('lighting with no camera image is not measured, not failed', () {
      final report = gate.evaluate(
        frame: framedFrame(),
        meanLuma: null,
        hasCameraImage: false,
      );

      final lighting = report[QualityCheckId.lighting]!;
      expect(lighting.result, QualityCheckResult.notMeasured);
      expect(lighting.failed, isFalse);
      expect(lighting.detail, contains('generated'));
      expect(report.passed, isTrue, reason: 'capture must not be blocked');
      expect(report.hasUnverifiedChecks, isTrue);
    });

    test('lighting with a camera image but no frame yet is pending', () {
      final report = gate.evaluate(
        frame: framedFrame(),
        meanLuma: null,
        hasCameraImage: true,
      );

      final lighting = report[QualityCheckId.lighting]!;
      expect(lighting.result, QualityCheckResult.notMeasured);
      expect(lighting.detail, contains('Hold the camera steady'));
      expect(report.passed, isTrue);
    });

    test('a starved stability window is not measured, not failed', () {
      // Regression: this used to return a failure, which deadlocked the static
      // test at the very first frame — the capture that would have produced the
      // frames was blocked by the check that needed them.
      final report = gate.evaluate(
        frame: framedFrame(),
        meanLuma: 0.5,
        recentFrames: const [],
        staticCapture: true,
      );

      final stability = report[QualityCheckId.stability]!;
      expect(stability.result, QualityCheckResult.notMeasured);
      expect(report.passed, isTrue);
    });

    test('an unmeasured check does not cap the aggregate score', () {
      final report = gate.evaluate(
        frame: framedFrame(),
        meanLuma: null,
        hasCameraImage: false,
        staticCapture: true,
        recentFrames: List.generate(12, (i) => framedFrame(t: i / 30)),
      );

      // A failure caps the aggregate at 0.4. An unmeasured check must not, or a
      // synthetic capture would be reported as a low-quality capture rather than
      // as an unverified one.
      expect(report.passed, isTrue);
      expect(report.score, greaterThan(0.4));
    });
  });

  group('a genuinely bad capture still fails', () {
    test('a dark frame fails the lighting check and blocks', () {
      final frame = framedFrame();
      final dark = gate.evaluate(
        frame: frame,
        meanLuma: 0.05,
        hasCameraImage: true,
      );
      final lit = gate.evaluate(
        frame: frame,
        meanLuma: 0.6,
        hasCameraImage: true,
      );

      expect(dark[QualityCheckId.lighting]!.result, QualityCheckResult.failed);
      expect(dark.passed, isFalse);

      // One hard failure caps the whole aggregate, so a capture that failed a
      // check can never read downstream as a good capture, and the same frame
      // under good lighting must score higher.
      expect(dark.score, lessThanOrEqualTo(0.4));
      expect(dark.score, lessThan(lit.score));
    });

    test('lateral hip drift fails stability for a static capture', () {
      // Note what this check measures: the horizontal hip centroid. Lateral
      // drift is what it detects, which is why the shifted frames below are the
      // case it must reject. Vertical bob during a static hold is a different
      // phenomenon and is not what this metric is for.
      final steady = List.generate(12, (i) => framedFrame(t: i / 30));
      final drifted = [
        ...steady.take(11),
        PoseFrame(
          timestampUs: steady.last.timestampUs,
          landmarks: steady.last.landmarks
              .map((l) => l.copyWith(x: l.x + 0.12))
              .toList(growable: false),
        ),
      ];

      expect(
        gate
            .evaluate(
              frame: steady.last,
              meanLuma: 0.5,
              recentFrames: steady,
              staticCapture: true,
            )[QualityCheckId.stability]!
            .result,
        QualityCheckResult.passed,
      );
      expect(
        gate
            .evaluate(
              frame: drifted.last,
              meanLuma: 0.5,
              recentFrames: drifted,
              staticCapture: true,
            )[QualityCheckId.stability]!
            .result,
        QualityCheckResult.failed,
      );
    });
  });

  group('the demonstration capture can actually start', () {
    test('a synthetic full-body figure satisfies the real framing rule', () {
      final report = gate.evaluate(
        frame: framedFrame(),
        meanLuma: null,
        hasCameraImage: false,
      );

      final framing = report[QualityCheckId.fullBodyInFrame]!;
      expect(
        framing.result,
        QualityCheckResult.passed,
        reason: 'the synthetic figure must be framed like the real patient this '
            'rule is written for, rather than the rule being relaxed for a demo',
      );
      expect(report[QualityCheckId.landmarkVisibility]!.result,
          QualityCheckResult.passed);
      expect(report[QualityCheckId.poseConfidence]!.result,
          QualityCheckResult.passed);
      expect(report.passed, isTrue);
    });

    test('every check result is serialised with its own outcome', () {
      final report = gate.evaluate(
        frame: framedFrame(),
        meanLuma: null,
        hasCameraImage: false,
      );

      final json = report.toJson();
      expect(json['passed'], isTrue);
      for (final check in json['checks'] as List) {
        expect(check['result'], isNotNull);
        expect(check['passed'], isNotNull);
      }
    });
  });
}
