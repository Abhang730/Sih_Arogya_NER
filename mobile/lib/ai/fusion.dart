// Confidence-aware multimodal fusion (PRD §17.5, §15.4, §15.5).
//
// PRD §15.5 and §17.5 both say the same thing: fusion behaviour must be LEARNED
// or CALIBRATED from validation data, "rather than fixed at arbitrary
// percentages". A hard-coded average of branch scores would violate that
// directly.
//
// So the weights here are never hard-coded. They come from a config asset that
// the ml/ pipeline writes after fitting on real data. When no fitted config is
// bundled, fusion still runs — because a field worker must never be blocked —
// but it runs with declared, reviewable, explicitly UNVALIDATED weights, and
// every downstream result says so. The distinction between "we fitted this" and
// "we wrote a defensible default and told you" is carried in the output, not in
// a comment.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../domain/protocol/models.dart';
import 'branch.dart';

/// Fusion coefficients.
class FusionConfig {
  const FusionConfig({
    required this.weights,
    required this.confidenceExponent,
    required this.calibrated,
    required this.provenance,
    this.dataset,
    this.fittedAt,
  });

  /// Branch wire name to weight.
  final Map<String, double> weights;

  /// Exponent applied to branch confidence. 1.0 weights linearly by confidence;
  /// higher values trust a high-confidence branch more sharply.
  final double confidenceExponent;

  /// True only when the weights were fitted and calibrated on held-out data.
  final bool calibrated;

  /// Where these numbers came from. Shown to the specialist verbatim, because
  /// "why did the app say high risk" needs an answer that is not a shrug.
  final String provenance;

  final String? dataset;
  final String? fittedAt;

  static const String assetPath = 'assets/models/fusion_config.json';

  /// Used until the ml/ pipeline fits real coefficients.
  ///
  /// Weighting rationale, stated so it can be argued with:
  ///   * the wearable branch is the highest-weighted evidence because it is the
  ///     only quantified biomechanical signal with real labelled training data;
  ///   * the clinical branch is next, because reported symptoms are the
  ///     strongest single predictor of care-seeking in this population;
  ///   * the camera branch carries the least weight because no labelled
  ///     monocular pose data exists, so any camera score is unvalidated;
  ///   * the imaging branch is optional supporting evidence (PRD §16.2) and
  ///     never dominates a field triage decision.
  static const FusionConfig uncalibratedDefault = FusionConfig(
    weights: {
      'imu_temporal': 0.40,
      'clinical_tabular': 0.35,
      'stage1_localisation': 0.15,
      'camera_temporal': 0.10,
      'imaging': 0.05,
    },
    confidenceExponent: 1.0,
    calibrated: false,
    provenance: 'UNVALIDATED DEFAULT — declared engineering weights, not '
        'fitted coefficients. PRD §15.5 requires these to be calibrated from '
        'validation data; until then the fused score is an uncalibrated index.',
  );

  double weightFor(ModelBranch branch) => weights[branch.wire] ?? 0.0;

  static Future<FusionConfig> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    try {
      final raw = await assets.loadString(assetPath);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final rawWeights = (decoded['weights'] as Map?)?.cast<String, dynamic>() ?? {};
      final weights = <String, double>{};
      rawWeights.forEach((key, value) {
        if (value is num) weights[key] = value.toDouble();
      });
      if (weights.isEmpty) return uncalibratedDefault;
      return FusionConfig(
        weights: weights,
        confidenceExponent:
            (decoded['confidence_exponent'] as num?)?.toDouble() ?? 1.0,
        calibrated: decoded['calibrated'] as bool? ?? false,
        provenance: decoded['provenance'] as String? ?? 'Fitted coefficients.',
        dataset: decoded['dataset'] as String?,
        fittedAt: decoded['fitted_at'] as String?,
      );
    } catch (_) {
      return uncalibratedDefault;
    }
  }
}

/// One branch's contribution to the fused result.
class BranchContribution {
  const BranchContribution({
    required this.branch,
    required this.score,
    required this.confidence,
    required this.declaredWeight,
    required this.effectiveWeight,
    required this.trainingStatus,
    required this.modelId,
    this.placementNote,
  });

  final ModelBranch branch;
  final double score;
  final double confidence;
  final double declaredWeight;

  /// declaredWeight adjusted by confidence. This is what actually drove the
  /// result, which is why it is reported separately: a branch with a huge weight
  /// and a terrible capture contributes almost nothing, and the specialist
  /// should be able to see that.
  final double effectiveWeight;

  final TrainingStatus trainingStatus;
  final String modelId;
  final String? placementNote;

  double get share => score * effectiveWeight;

  Map<String, dynamic> toJson() => {
        'branch': branch.wire,
        'model_id': modelId,
        'score': score,
        'confidence': confidence,
        'declared_weight': declaredWeight,
        'effective_weight': effectiveWeight,
        'training_status': trainingStatus.wire,
        if (placementNote != null) 'placement_note': placementNote,
      };
}

class FusionResult {
  const FusionResult({
    required this.score,
    required this.band,
    required this.contributions,
    required this.allBranches,
    required this.caveats,
    required this.isCalibrated,
    required this.configProvenance,
    required this.agreement,
    required this.referralActionKey,
  });

  /// Null when no branch could score. Never zero — zero would read as
  /// "no risk", which is a different and unsupported statement from "we could
  /// not assess this".
  final double? score;

  final RiskBand? band;
  final List<BranchContribution> contributions;

  /// Every branch, including the ones that could not score, so the UI can
  /// explain each absence (PRD §19.2 "never hide a failed quality check").
  final List<BranchScore> allBranches;

  /// Everything a reader must know to interpret this result correctly.
  final List<String> caveats;

  final bool isCalibrated;
  final String configProvenance;

  /// 1.0 = every scoring branch agrees. Low agreement is itself a finding.
  final double agreement;

  final String referralActionKey;

  bool get hasScore => score != null;

  /// True when the only evidence is the untrained-or-prototype kind, i.e. this
  /// result must not be presented as a model output.
  bool get isPrototypeOnly => contributions.isNotEmpty &&
      contributions.every((c) =>
          c.trainingStatus == TrainingStatus.prototypeRuleBased ||
          c.trainingStatus == TrainingStatus.planned);

  Map<String, dynamic> toJson() => {
        'score': score,
        'band': band?.id,
        'referral_action': referralActionKey,
        'calibrated': isCalibrated,
        'agreement': agreement,
        'contributions': contributions.map((c) => c.toJson()).toList(growable: false),
        'branches': allBranches.map((b) => b.toJson()).toList(growable: false),
        'caveats': caveats,
        'config_provenance': configProvenance,
      };
}

/// Combines branch scores into one screening indication.
class MultimodalFusion {
  MultimodalFusion({
    required this.protocol,
    required this.config,
    this.minConfidenceExponentFloor = 0.2,
  });

  final JointProtocol protocol;
  final FusionConfig config;

  /// Floor applied to confidence before it is exponentiated.
  ///
  /// Without a floor, a capture with confidence 0 would zero a branch's
  /// effective weight entirely. A branch that produced a score at all did so
  /// from *some* usable data, so it should retain a small influence rather than
  /// being silently erased by a rounding-level confidence value.
  final double minConfidenceExponentFloor;

  FusionResult fuse(List<BranchScore> branches, {Map<String, Object?>? extraContext}) {
    final caveats = <String>[];

    if (!config.calibrated) {
      caveats.add(
        'Fusion weights are an uncalibrated default, not fitted coefficients. '
        'The combined score is an index for triage, not a probability.',
      );
    }
    if (protocol.riskLogic.isPlaceholder) {
      caveats.add(
        'Risk band thresholds are configurable placeholders, not validated '
        'operating points. They must be re-derived from pilot data.',
      );
    }

    final eligible = branches.where((b) => b.canEnterFusion).toList(growable: false);
    final contributions = <BranchContribution>[];
    final availableWeights = <double>[];

    for (final branch in eligible) {
      final score = branch.score;
      if (score == null) continue;

      final declared = config.weightFor(branch.branch);
      if (declared <= 0) continue;

      final confidence = branch.confidence.clamp(0.0, 1.0).toDouble();
      final floored = math.max(confidence, minConfidenceExponentFloor);
      final effective = declared * math.pow(floored, config.confidenceExponent).toDouble();

      contributions.add(BranchContribution(
        branch: branch.branch,
        score: score,
        confidence: confidence,
        declaredWeight: declared,
        effectiveWeight: effective,
        trainingStatus: branch.trainingStatus,
        modelId: branch.modelId,
        placementNote: branch.placementNote,
      ));
      availableWeights.add(effective);
    }

    // Explain every branch that could not contribute. An unexplained absence is
    // indistinguishable from a bug to the person reading the result.
    for (final branch in branches) {
      if (branch.isAvailable) continue;
      caveats.add(
        '${branch.branch.displayName}: ${branch.reason?.explanation ?? 'unavailable.'}',
      );
    }

    if (contributions.isEmpty) {
      return FusionResult(
        score: null,
        band: null,
        contributions: const [],
        allBranches: branches,
        caveats: [
          ...caveats,
          'No branch could produce a score for this assessment, so no combined '
              'screening indication is shown. The measurements above are still '
              'valid and should be reviewed clinically.',
        ],
        isCalibrated: config.calibrated,
        configProvenance: config.provenance,
        agreement: 0,
        referralActionKey: 'action.clinical_review',
      );
    }

    final totalWeight = availableWeights.fold<double>(0, (a, b) => a + b);
    final weightedSum = contributions
        .fold<double>(0, (sum, c) => sum + (c.score * c.effectiveWeight));
    final score = (weightedSum / totalWeight).clamp(0.0, 1.0).toDouble();

    final agreement = _agreement(contributions);
    if (contributions.length > 1 && agreement < 0.6) {
      caveats.add(
        'The branches disagree substantially (agreement ${(agreement * 100).round()}%). '
        'Treat this case as uncertain and prefer clinical review.',
      );
    }

    for (final contribution in contributions) {
      if (contribution.confidence < 0.5) {
        caveats.add(
          '${contribution.branch.displayName} contributed with low capture '
          'confidence (${(contribution.confidence * 100).round()}%).',
        );
      }
      if (contribution.placementNote != null) {
        caveats.add(
          '${contribution.branch.displayName}: ${contribution.placementNote}',
        );
      }
    }

    final band = protocol.riskLogic.bandFor(score);

    return FusionResult(
      score: score,
      band: band,
      contributions: contributions
        ..sort((a, b) => b.share.compareTo(a.share)),
      allBranches: branches,
      caveats: caveats,
      isCalibrated: config.calibrated,
      configProvenance: config.provenance,
      agreement: agreement,
      referralActionKey: band.actionKey,
    );
  }

  /// Agreement between branch scores as 1 - normalised spread.
  ///
  /// Uses the range rather than the standard deviation because with two or three
  /// branches a standard deviation is dominated by sample size, which would make
  /// the same clinical disagreement read differently depending on how many
  /// branches happened to be available.
  double _agreement(List<BranchContribution> contributions) {
    if (contributions.length < 2) return 1.0;
    final scores = contributions.map((c) => c.score).toList();
    final spread = (scores.reduce(math.max) - scores.reduce(math.min));
    return (1.0 - spread).clamp(0.0, 1.0).toDouble();
  }
}
