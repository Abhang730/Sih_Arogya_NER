// Clinical branch (PRD §17.3).
//
// PRD §17.3 specifies XGBoost with SHAP attribution for this branch. That needs
// a labelled tabular dataset and a training run, which is the job of
// ml/clinical_xgb. Until that artefact exists and is bundled, this class
// produces an EXPLICITLY LABELLED rule-based prototype.
//
// The distinction is not cosmetic. A hand-written rule published as a model
// output is exactly the unmeasured claim PRD §26.5 prohibits, so:
//
//   * the score carries trainingStatus = prototypeRuleBased;
//   * the UI and the report render the honesty notice beside it;
//   * the output is marked uncalibrated, because a linear rule over raw clinical
//     scores does not produce a calibrated probability.
//
// Every weight below is a documented clinical heuristic, not a fitted
// parameter. When the real model lands, TfliteBranch replaces this class and the
// honesty notice changes on its own.

import 'dart:math' as math;

import '../domain/protocol/models.dart';
import '../domain/protocol/scoring.dart';
import 'branch.dart';

/// One weighted input in the prototype rule.
///
/// Each rule resolves its own raw value from whatever source actually holds it —
/// a questionnaire subscale, a captured feature, or a demographic. That
/// indirection matters: an earlier version gated the questionnaire rules on
/// feature keys that the questionnaire never populates, so they silently never
/// fired and the score quietly became "age only". A rule that cannot find its
/// input must be visibly skipped, never quietly empty.
class _Rule {
  const _Rule({
    required this.key,
    required this.weight,
    required this.label,
    required this.resolve,
    required this.normalise,
  });

  /// Stable identifier recorded in the explanation.
  final String key;
  final double weight;

  /// Plain-language description shown to the specialist and the patient
  /// (PRD §24.2).
  final String label;

  /// Raw value, or null when this input genuinely was not captured.
  final double? Function(BranchInput input) resolve;

  /// Maps the raw value onto 0..1.
  final double Function(double raw) normalise;
}

class ClinicalPrototypeBranch implements ScoringBranch {
  ClinicalPrototypeBranch({required this.spec, required this.protocol});

  @override
  final ModelSpec spec;

  final JointProtocol protocol;

  @override
  Future<bool> get isReady async => true;

  /// Normalises a questionnaire subscale to 0..1 using its declared maximum, so
  /// the rule is driven by the protocol rather than by hard-coded WOMAC numbers.
  double _subscaleFraction(QuestionnaireScore score, String name, double fallbackMax) {
    final sub = score.subscale(name);
    if (sub == null) return 0;
    final max = sub.max == 0 ? fallbackMax : sub.max;
    return (sub.raw / max).clamp(0.0, 1.0).toDouble();
  }

  List<_Rule> _rules() => [
        _Rule(
          key: 'womac_pain',
          weight: 0.40,
          label: 'Reported knee pain',
          resolve: (input) {
            final q = input.questionnaireScore;
            return q is QuestionnaireScore ? q.subscale('pain')?.raw : null;
          },
          normalise: (raw) => 0,
        ),
        _Rule(
          key: 'womac_function',
          weight: 0.35,
          label: 'Reported difficulty with daily activities',
          resolve: (input) {
            final q = input.questionnaireScore;
            return q is QuestionnaireScore ? q.subscale('function')?.raw : null;
          },
          normalise: (raw) => 0,
        ),
        _Rule(
          key: 'womac_stiffness',
          // Deliberately the smallest clinical weight: the WOMAC stiffness
          // subscale has notably weaker test-retest reliability than pain and
          // function, so equal weighting would let a noisy subscale move the
          // result.
          weight: 0.10,
          label: 'Reported morning stiffness',
          resolve: (input) {
            final q = input.questionnaireScore;
            return q is QuestionnaireScore ? q.subscale('stiffness')?.raw : null;
          },
          normalise: (raw) => 0,
        ),
        _Rule(
          key: 'age',
          weight: 0.15,
          label: 'Age',
          resolve: (input) => input['age'],
          // Age is a genuine non-modifiable risk factor for OA. Scaled linearly
          // from 40 to 80 years: a documented heuristic, not a fitted curve.
          normalise: (raw) => ((raw - 40) / 40).clamp(0.0, 1.0).toDouble(),
        ),
      ];

  @override
  Future<BranchScore> score(BranchInput input) async {
    final questionnaire = input.questionnaireScore;
    if (questionnaire is! QuestionnaireScore || !questionnaire.isComplete) {
      return BranchScore.unavailable(
        branch: ModelBranch.clinicalTabular,
        reason: BranchUnavailableReason.missingInput,
        modelId: spec.modelId,
        modelVersion: spec.version,
        trainingStatus: TrainingStatus.prototypeRuleBased,
      );
    }

    final contributions = <FeatureContribution>[];
    var weighted = 0.0;
    var weightSum = 0.0;

    for (final rule in _rules()) {
      final raw = rule.resolve(input);
      // A rule whose input is absent is skipped and its weight redistributed,
      // rather than being treated as zero. Treating a missing age as "age 40"
      // would understate risk for an older patient.
      if (raw == null) continue;

      final double normalised;
      if (rule.key.startsWith('womac_')) {
        normalised = _subscaleFraction(
          questionnaire,
          rule.key.substring('womac_'.length),
          1,
        );
      } else {
        normalised = (raw).isFinite ? rule.normalise(raw).clamp(0.0, 1.0).toDouble() : 0;
      }

      contributions.add(FeatureContribution(
        featureKey: rule.key,
        value: raw,
        contribution: normalised * rule.weight,
        label: rule.label,
      ));
      weighted += normalised * rule.weight;
      weightSum += rule.weight;
    }

    if (weightSum == 0) {
      return BranchScore.unavailable(
        branch: ModelBranch.clinicalTabular,
        reason: BranchUnavailableReason.missingInput,
        modelId: spec.modelId,
        modelVersion: spec.version,
        trainingStatus: TrainingStatus.prototypeRuleBased,
      );
    }

    // Renormalise by the weights actually available, so a skipped rule
    // redistributes influence instead of depressing the score artificially.
    final normalisedScore = (weighted / weightSum).clamp(0.0, 1.0).toDouble();

    return BranchScore(
      branch: ModelBranch.clinicalTabular,
      score: normalisedScore,
      confidence: input.confidenceFor('questionnaire'),
      trainingStatus: TrainingStatus.prototypeRuleBased,
      modelId: spec.modelId,
      modelVersion: spec.version,
      contributions: contributions
        ..sort((a, b) => b.contribution.compareTo(a.contribution)),
      limitations: const [
        'Rule-based prototype, not a fitted model: the weights are documented '
            'clinical heuristics rather than parameters learned from data.',
        'The output is not a calibrated probability and must not be read as one.',
        'Not validated in the North Eastern Region, or anywhere else.',
      ],
    );
  }

  /// Spread between the largest and smallest contributions, capped at 1.
  ///
  /// Lets the fusion layer distinguish a strongly-driven score from a marginal
  /// one without inventing a threshold.
  static double spread(List<FeatureContribution> contributions) {
    if (contributions.length < 2) return 0;
    final values = contributions.map((c) => c.contribution).toList()..sort();
    return math.min(1.0, values.last - values.first);
  }
}
