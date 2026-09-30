// Scoring branches (PRD §17).
//
// Every branch returns a [BranchScore] that carries its own provenance: which
// model produced it, what version, whether that model is actually trained, and
// what measured how confident the input was.
//
// The provenance travels with the number rather than being looked up later.
// That is deliberate. PRD §26.5 forbids unmeasured claims, and the easiest way
// to break that rule accidentally is to let a score lose its context somewhere
// between the model and the report. Here it is structurally impossible: a score
// cannot exist without stating where it came from.

import '../domain/protocol/models.dart';

/// Why a branch could not produce a score.
enum BranchUnavailableReason {
  /// No trained artefact exists for this branch. Reportable, and expected —
  /// PRD §12.2 only promises a complete module for the knee.
  untrained,

  /// The trained artefact exists but the input for this capture is missing.
  missingInput,

  /// The input exists but its quality is too low to trust.
  lowInputQuality,

  /// An implementation gap: the branch is declared but not wired up.
  notImplemented,

  /// The manifest says this model was trained, but the bundled artefact could
  /// not be loaded. Distinct from [untrained] on purpose: one means "no model
  /// exists yet", the other means "a model exists and this build cannot find
  /// it", and a build that conflated them would hide a packaging defect behind
  /// an expected limitation.
  artefactUnavailable,

  /// This platform has no on-device model runner at all (the web build). The
  /// measurement was not taken here — it is not a zero and not a low score.
  platformUnsupported;

  String get wire => switch (this) {
        BranchUnavailableReason.untrained => 'untrained',
        BranchUnavailableReason.missingInput => 'missing_input',
        BranchUnavailableReason.lowInputQuality => 'low_input_quality',
        BranchUnavailableReason.notImplemented => 'not_implemented',
        BranchUnavailableReason.artefactUnavailable => 'artefact_unavailable',
        BranchUnavailableReason.platformUnsupported => 'platform_unsupported',
      };

  /// Worker-facing explanation. Plain language, no jargon: an ASHA worker has to
  /// be able to explain to a patient why a reading is missing.
  String get explanation => switch (this) {
        BranchUnavailableReason.untrained =>
          'This measurement is not available yet — no validated model has been '
              'trained for it.',
        BranchUnavailableReason.missingInput =>
          'This measurement was skipped because the required data was not captured.',
        BranchUnavailableReason.lowInputQuality =>
          'This measurement was skipped because the capture quality was too low '
              'to rely on.',
        BranchUnavailableReason.notImplemented =>
          'This measurement is not implemented for this joint yet.',
        BranchUnavailableReason.artefactUnavailable =>
          'The model for this measurement is declared as trained but its file '
              'is not present in this build, so the measurement was not taken.',
        BranchUnavailableReason.platformUnsupported =>
          'This measurement needs the on-device model runner, which this build '
              'does not include. The measurement was not taken here.',
      };
}

/// A single feature's contribution to a branch score, for the explanation layer
/// (PRD §17.3, §23.2, §24.2).
class FeatureContribution {
  const FeatureContribution({
    required this.featureKey,
    required this.value,
    required this.contribution,
    required this.label,
  });

  final String featureKey;

  /// The measured value, in the feature's own unit.
  final double value;

  /// Signed contribution to the score. Positive pushes towards higher
  /// screening priority. These are additive and sum to the branch score's
  /// distance from its baseline.
  final double contribution;

  /// Plain-language description of what this contributor means, safe to show a
  /// patient or a specialist (PRD §24.2).
  final String label;

  Map<String, dynamic> toJson() => {
        'feature': featureKey,
        'value': value,
        'contribution': contribution,
        'label': label,
      };
}

/// A score from one branch, with everything needed to interpret it honestly.
class BranchScore {
  const BranchScore({
    required this.branch,
    required this.score,
    required this.confidence,
    required this.trainingStatus,
    required this.modelId,
    required this.modelVersion,
    required this.contributions,
    required this.limitations,
    this.placementNote,
    this.attributionMethod = 'feature_attribution',
  })  : reason = null,
        _available = true;

  /// Constructs an explicitly unavailable branch. Note there is no way to build
  /// a BranchScore without a score and an unavailable one at the same time,
  /// which is the point.
  const BranchScore.unavailable({
    required this.branch,
    required this.reason,
    required this.modelId,
    required this.modelVersion,
    required this.trainingStatus,
  })  : score = null,
        confidence = 0,
        contributions = const [],
        limitations = const [],
        placementNote = null,
        attributionMethod = 'none',
        _available = false;

  final ModelBranch branch;

  /// Null when the branch could not score. Callers must handle null rather than
  /// treating a missing score as zero, which would silently drag fusion towards
  /// "no risk".
  final double? score;

  /// 0..1 confidence in the input data, sourced from the quality gate or the
  /// sensor quality engine (PRD §15.4).
  final double confidence;

  final TrainingStatus trainingStatus;
  final String modelId;
  final String modelVersion;
  final List<FeatureContribution> contributions;
  final List<String> limitations;

  /// Set when the model was trained at a different sensor placement from the
  /// protocol's, so a specialist never reads it as the intended measurement.
  final String? placementNote;

  /// 'shap' only when a real SHAP explainer produced the attributions.
  /// A linear hand-rolled attribution reports 'feature_attribution'.
  final String attributionMethod;

  final BranchUnavailableReason? reason;
  final bool _available;

  bool get isAvailable => _available;

  /// Whether this score may enter fusion.
  ///
  /// PRD §15.5: degradation behaviour should come from validation, not from
  /// fixed percentages. So a branch is only excluded for a *structural* reason
  /// (no score, or a model that was never trained) — never because its
  /// confidence happened to be low in a way someone guessed a cut-off for. Low
  /// confidence is passed through and handled by the calibrated weight instead.
  bool get canEnterFusion =>
      isAvailable && score != null && trainingStatus.canScore;

  /// Rendered next to every score in the UI and the report.
  String get honestyNotice {
    final base = trainingStatus.honestyLabel;
    if (placementNote == null) return base;
    return '$base. $placementNote';
  }

  Map<String, dynamic> toJson() => {
        'branch': branch.wire,
        'available': isAvailable,
        if (reason != null) 'reason': reason!.wire,
        if (score != null) 'score': score,
        'confidence': confidence,
        'training_status': trainingStatus.wire,
        'model_id': modelId,
        'model_version': modelVersion,
        'attribution_method': attributionMethod,
        'contributions': contributions.map((c) => c.toJson()).toList(growable: false),
        'limitations': limitations,
        if (placementNote != null) 'placement_note': placementNote,
      };
}

/// The input a branch is given.
class BranchInput {
  const BranchInput({
    required this.features,
    required this.featureConfidence,
    this.questionnaireScore,
    this.modalityConfidence = const {},
  });

  /// Feature key to measured value. Only features the extractor actually
  /// produced appear here — absent features stay absent (PRD §15.4, §26.5).
  final Map<String, double> features;

  /// Per-feature confidence, so a branch can weight its own inputs.
  final Map<String, double> featureConfidence;

  final Object? questionnaireScore;

  /// Confidence per modality ('camera', 'wearable', 'questionnaire').
  final Map<String, double> modalityConfidence;

  bool has(String key) => features.containsKey(key);

  double? operator [](String key) => features[key];

  double confidenceFor(String modality) => modalityConfidence[modality] ?? 0;
}

/// A model branch.
abstract class ScoringBranch {
  /// Protocol model metadata this branch implements.
  ModelSpec get spec;

  /// Whether this branch can produce a score at all right now.
  Future<bool> get isReady;

  /// Scores the input, or returns an unavailable result. Implementations must
  /// never invent a score to satisfy a caller.
  Future<BranchScore> score(BranchInput input);
}
