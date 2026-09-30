// The joint feature engine and fusion runner (PRD §36, §17).
//
// This is the layer the canonical architecture diagram puts between the
// measurements and the result:
//
//     Clinical / Camera / Sensor  →  feature engine  →  branches  →  fusion
//
// It is deliberately the ONLY place that decides which branches run, and it
// decides that from the protocol's own `models` list rather than from a switch
// on the joint name. Adding a joint means adding a protocol (PRD §12.1).
//
// The honesty rules this file is responsible for:
//
//   * A branch declared in the protocol but untrained still runs, and returns
//     itself as unavailable WITH a reason. It is never silently omitted, because
//     an unexplained missing branch is indistinguishable from a bug.
//   * A missing feature stays missing. Nothing is zero-filled, because a
//     zero-filled feature is an imputed value presented as a measurement.
//   * Modality confidence comes from the quality gate and the sensor quality
//     engine, never from the model, so a good model fed a bad capture still
//     reports honestly (PRD §15.4).

import 'dart:math' as math;

import '../ai/branch.dart';
import '../ai/clinical_branch.dart';
import '../ai/fusion.dart';
import '../ai/stage1_localizer.dart';
import '../ai/tflite_branch.dart';
import '../domain/protocol/models.dart';
import '../domain/protocol/registry.dart';
import '../domain/protocol/scoring.dart';
import '../pose/feature_extractor.dart';
import '../pose/pose_types.dart';
import '../pose/quality_gate.dart';
import '../wearable/imu_features.dart';

/// One movement test's captured frames, with its provenance.
class TestCapture {
  const TestCapture({
    required this.testId,
    required this.frames,
    required this.poseEngineId,
    required this.poseEngineSynthetic,
    this.meanLuma,
    this.quality,
  });

  final String testId;
  final List<PoseFrame> frames;
  final String poseEngineId;

  /// Whether these frames were generated. Recorded so a synthetic capture can
  /// never later be read as a measurement.
  final bool poseEngineSynthetic;

  final double? meanLuma;
  final QualityReport? quality;
}

/// Everything a joint assessment produced.
class JointAssessmentOutcome {
  const JointAssessmentOutcome({
    required this.jointId,
    required this.side,
    required this.protocolVersion,
    required this.features,
    required this.testResults,
    required this.movementSeries,
    required this.imuFeatures,
    required this.cameraConfidence,
    required this.sensorPlacement,
    required this.questionnaire,
    required this.fusion,
    required this.stage1Map,
    required this.caveats,
    required this.syntheticCapture,
  });

  final String jointId;
  final String side;
  final String protocolVersion;

  /// Camera-derived features, merged across every movement test.
  final Map<String, double> features;

  /// Per-test detail, so the movement view can show a failure per test rather
  /// than one merged result (PRD §23.1).
  final Map<String, FeatureExtractionResult> testResults;

  /// Angle and timing series for the dashboard movement view.
  final Map<String, Map<String, double>> movementSeries;

  final Map<String, double> imuFeatures;

  /// 0..1 camera capture confidence, from the feature extractor.
  final double cameraConfidence;

  /// The placement sensor data was actually captured at, when any was.
  final String? sensorPlacement;

  final QuestionnaireScore? questionnaire;
  final FusionResult fusion;

  /// Stage-1 localisation, re-run with this assessment's own evidence so the
  /// stored Stage-1 result and the joint result cannot disagree.
  final JointRiskMap? stage1Map;

  final List<String> caveats;

  /// True when any part of this assessment used generated landmarks.
  final bool syntheticCapture;

  /// Every protocol-declared camera feature that could not be measured. Surfaced
  /// rather than dropped (PRD §19.2 "never hide a failed quality check").
  List<String> missingFeatures(JointProtocol protocol) {
    final declared = protocol.featurePipeline
        .where((f) => f.source == FeatureSource.camera)
        .map((f) => f.key)
        .toSet();
    return declared.where((k) => !features.containsKey(k)).toList(growable: false);
  }
}

class JointAssessmentEngine {
  JointAssessmentEngine({
    required this.registry,
    required this.manifest,
    required this.fusionConfig,
    this.qualityConfig,
  });

  final ProtocolRegistry registry;
  final ModelManifest manifest;
  final FusionConfig fusionConfig;
  final QualityGateConfig? qualityConfig;

  /// Runs a full joint assessment.
  ///
  /// [imuTrial] is null when no pod was used, which is a supported and expected
  /// configuration: PRD §14 stresses the wearable is optional and comes after
  /// Stage 1.
  Future<JointAssessmentOutcome> run({
    required JointProtocol protocol,
    required String side,
    required List<TestCapture> captures,
    Map<String, double> clinicalInputs = const {},
    QuestionnaireScore? questionnaire,
    ImuTrial? imuTrial,
    double questionnaireConfidence = 0,
  }) async {
    final caveats = <String>[];

    // ── camera features ────────────────────────────────────────────────────
    final extractor = FeatureExtractor(
      topology: registry.landmarks,
      protocol: protocol,
    );

    final features = <String, double>{};
    final featureConfidence = <String, double>{};
    final testResults = <String, FeatureExtractionResult>{};
    final movementSeries = <String, Map<String, double>>{};

    for (final capture in captures) {
      final test = protocol.movementTests.where((t) => t.id == capture.testId);
      if (test.isEmpty) continue;
      final movementTest = test.first;

      final result = extractor.extract(test: movementTest, frames: capture.frames);
      testResults[movementTest.id] = result;

      result.features.forEach((key, value) {
        // A later test overwrites an earlier one for the same key, which is
        // intended: the protocol orders tests so the most specific capture is
        // last, and duplicating a key across tests means "this test supersedes".
        features[key] = value;
        featureConfidence[key] = result.confidence;
      });

      // Series are stored as length plus a compact summary rather than every
      // sample: a few seconds at 30 fps is thousands of points per axis, and
      // the dashboard needs the shape, not the raw buffer (PRD §25.3).
      for (final entry in result.series.entries) {
        if (entry.value.isEmpty) continue;
        movementSeries['${movementTest.id}.${entry.key}'] = {
          'n': entry.value.length.toDouble(),
          'mean': _mean(entry.value),
          'min': entry.value.reduce(math.min),
          'max': entry.value.reduce(math.max),
        };
      }

      if (capture.poseEngineSynthetic) {
        caveats.add(
          'The "${movementTest.nameKey}" capture used SIMULATED landmarks '
          '(${capture.poseEngineId}), so its measurements are not of this '
          'patient.',
        );
      }
      if (!result.hasUsableData) {
        caveats.add(
          'The "${movementTest.nameKey}" capture produced no usable '
          'measurements: ${result.notes.join(' ')}',
        );
      }
    }

    final cameraConfidence = _aggregateConfidence(testResults.values);
    if (cameraConfidence < 0.5 && testResults.isNotEmpty) {
      caveats.add(
        'Camera capture confidence was low '
        '(${(cameraConfidence * 100).round()}%). Any camera-derived component '
        'should be treated as indicative only.',
      );
    }

    // ── sensor features ────────────────────────────────────────────────────
    final imuFeatures = <String, double>{};
    var sensorConfidence = 0.0;
    String? sensorPlacement;

    if (imuTrial != null) {
      imuFeatures.addAll(extractImuFeatures(imuTrial));
      sensorConfidence = imuFeatures['imu_signal_quality'] ?? 0;

      // PRD §14.3 intends thigh + shin. The trained artefact came from a
      // lumbar-L5 + dorsal-foot rig, so this records what the PROTOCOL intends
      // and the model's own placement_note is carried through fusion as a caveat
      // (DECISIONS.md D3). The two are stored separately on purpose: the sensor
      // placement actually used, and the placement the model was trained at.
      sensorPlacement = protocol.wearable.preferred?.pods
          .map((pod) => pod.placementKey)
          .join('+');

      if (!imuFeatures.containsKey('imu_proximal_distal_correlation')) {
        caveats.add(
          'Only one pod contributed, so proximal-distal coupling could not be '
          'measured. Those features are absent rather than zero.',
        );
      }
      if (sensorConfidence < 0.7) {
        caveats.add(
          'Motion Pod signal quality was '
          '${(sensorConfidence * 100).round()}%. Check the pod placement before '
          'relying on the sensor component.',
        );
      }
    }

    // ── branch inputs ──────────────────────────────────────────────────────
    final combinedFeatures = <String, double>{
      ...clinicalInputs,
      ...features,
      ...imuFeatures,
    };

    final input = BranchInput(
      features: combinedFeatures,
      featureConfidence: {
        ...featureConfidence,
        for (final key in imuFeatures.keys) key: sensorConfidence,
      },
      questionnaireScore: questionnaire,
      modalityConfidence: {
        'camera': cameraConfidence,
        'wearable': sensorConfidence,
        'questionnaire': questionnaireConfidence,
      },
    );

    // ── branches, exactly as the protocol declares them ────────────────────
    final branches = <BranchScore>[];
    for (final spec in protocol.models) {
      if (spec.branch == ModelBranch.fusion || spec.branch == ModelBranch.imaging) {
        // Fusion is performed below; imaging is optional supporting evidence
        // with no bundled model (PRD §16.2).
        continue;
      }
      branches.add(await _scoreBranch(spec, protocol, input));
    }

    // ── fusion ─────────────────────────────────────────────────────────────
    final fusion = MultimodalFusion(protocol: protocol, config: fusionConfig)
        .fuse(branches);

    // ── Stage-1 map, recomputed from this assessment's own evidence ─────────
    final localizer = Stage1Localizer(
      registry: registry,
      manifest: manifest,
      branchInput: input,
    );
    final stage1Map = await localizer.localize();

    caveats.addAll(fusion.caveats);

    return JointAssessmentOutcome(
      jointId: protocol.jointId,
      side: side,
      protocolVersion: protocol.protocolVersion,
      features: features,
      testResults: testResults,
      movementSeries: movementSeries,
      imuFeatures: imuFeatures,
      cameraConfidence: cameraConfidence,
      sensorPlacement: sensorPlacement,
      questionnaire: questionnaire,
      fusion: fusion,
      stage1Map: stage1Map,
      caveats: caveats,
      syntheticCapture: captures.any((c) => c.poseEngineSynthetic),
    );
  }

  /// Chooses the implementation for one declared branch.
  ///
  /// A trained artefact uses [TfliteBranch]. The clinical branch has a declared
  /// prototype until an XGBoost artefact is bundled, so it uses
  /// [ClinicalPrototypeBranch] — which labels itself as a rule-based prototype
  /// rather than passing hand-written weights off as a fitted model.
  Future<BranchScore> _scoreBranch(
    ModelSpec spec,
    JointProtocol protocol,
    BranchInput input,
  ) async {
    if (spec.branch == ModelBranch.clinicalTabular) {
      final entry = manifest[spec.modelId];
      if (entry == null || !entry.isUsable) {
        return ClinicalPrototypeBranch(spec: spec, protocol: protocol)
            .score(input);
      }
    }

    final branch = TfliteBranch(spec: spec, manifest: manifest);
    final result = await branch.score(input);
    branch.dispose();
    return result;
  }

  /// Confidence for the camera modality across the tests that produced data.
  ///
  /// Weighted by frame count rather than averaged, so a long capture does not
  /// carry the same weight as a two-frame one.
  static double _aggregateConfidence(Iterable<FeatureExtractionResult> results) {
    var weighted = 0.0;
    var frames = 0;
    for (final result in results) {
      if (result.frameCount == 0) continue;
      weighted += result.confidence * result.frameCount;
      frames += result.frameCount;
    }
    return frames == 0 ? 0 : (weighted / frames).clamp(0.0, 1.0);
  }

  static double _mean(List<double> values) =>
      values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;
}
