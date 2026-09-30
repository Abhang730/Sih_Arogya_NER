// Fusion and branch-honesty tests.
//
// These are the tests that protect the PRD's binding guardrails (§1.2, §15.5,
// §26.5). The failure they exist to prevent is subtle and serious: a number
// appearing in a report without the context that makes it interpretable, or a
// missing measurement being silently read as "no risk".

import 'package:arogya_ner/ai/branch.dart';
import 'package:arogya_ner/ai/clinical_branch.dart';
import 'package:arogya_ner/ai/fusion.dart';
import 'package:arogya_ner/ai/stage1_localizer.dart';
import 'package:arogya_ner/ai/tflite_branch.dart';
import 'package:arogya_ner/domain/protocol/models.dart';
import 'package:arogya_ner/domain/protocol/registry.dart';
import 'package:arogya_ner/domain/protocol/scoring.dart';
import 'package:flutter_test/flutter_test.dart';

BranchScore scored({
  ModelBranch branch = ModelBranch.imuTemporal,
  required double score,
  double confidence = 0.9,
  TrainingStatus status = TrainingStatus.trained,
  String? placementNote,
}) =>
    BranchScore(
      branch: branch,
      score: score,
      confidence: confidence,
      trainingStatus: status,
      modelId: 'test_model',
      modelVersion: '1.0.0',
      contributions: const [],
      limitations: const [],
      placementNote: placementNote,
    );

BranchScore unavailable(
  ModelBranch branch,
  BranchUnavailableReason reason, {
  TrainingStatus status = TrainingStatus.untrainedInsufficientData,
}) =>
    BranchScore.unavailable(
      branch: branch,
      reason: reason,
      modelId: 'test_model',
      modelVersion: '0.0.0',
      trainingStatus: status,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProtocolRegistry registry;
  late JointProtocol knee;

  setUpAll(() async {
    registry = await ProtocolRegistry.load();
    knee = registry.protocolFor('knee');
  });

  MultimodalFusion fusion({FusionConfig? config}) => MultimodalFusion(
        protocol: knee,
        config: config ?? FusionConfig.uncalibratedDefault,
      );

  group('a missing measurement is never presented as low risk', () {
    test('no scoring branch yields a null score, not zero', () {
      final result = fusion().fuse([
        unavailable(ModelBranch.cameraTemporal, BranchUnavailableReason.untrained),
        unavailable(ModelBranch.imuTemporal, BranchUnavailableReason.untrained),
      ]);

      expect(result.hasScore, isFalse);
      expect(result.score, isNull,
          reason: 'zero would read as "no risk"; the truth is "not assessed"');
      expect(result.band, isNull);
      expect(result.referralActionKey, 'action.clinical_review');
    });

    test('every unavailable branch is explained in the caveats', () {
      final result = fusion().fuse([
        unavailable(ModelBranch.cameraTemporal, BranchUnavailableReason.untrained),
        unavailable(ModelBranch.imuTemporal, BranchUnavailableReason.lowInputQuality),
      ]);

      final joined = result.caveats.join(' ');
      expect(joined, contains('Camera movement'));
      expect(joined, contains('Wearable sensor'));
      // The failure mode this guards: an absence with no explanation is
      // indistinguishable from a bug to the person reading the report.
      expect(result.caveats.length, greaterThanOrEqualTo(4));
    });
  });

  group('untrained branches cannot influence the result', () {
    test('a trained branch scores while an untrained one is excluded', () {
      final result = fusion().fuse([
        scored(score: 0.8, confidence: 1.0),
        unavailable(ModelBranch.cameraTemporal, BranchUnavailableReason.untrained),
        unavailable(ModelBranch.clinicalTabular, BranchUnavailableReason.untrained),
      ]);

      expect(result.hasScore, isTrue);
      expect(result.contributions, hasLength(1));
      expect(result.contributions.first.branch, ModelBranch.imuTemporal);
      // With the only scoring branch at 0.8, the fused score is 0.8.
      expect(result.score, closeTo(0.8, 1e-9));
    });

    test('a prototype branch is excluded when its input is incomplete', () async {
      final spec = knee.modelFor(ModelBranch.clinicalTabular)!;
      final branch = ClinicalPrototypeBranch(spec: spec, protocol: knee);

      final result = await branch.score(BranchInput(
        features: const {'age': 62},
        featureConfidence: const {},
        modalityConfidence: const {'questionnaire': 0.9},
      ));

      expect(result.isAvailable, isFalse);
      expect(result.reason, BranchUnavailableReason.missingInput);
      expect(result.score, isNull);
    });
  });

  group('confidence genuinely changes influence', () {
    test('a confident branch outweighs a poorly captured one', () {
      final result = fusion().fuse([
        scored(score: 0.9, confidence: 1.0),
        scored(
          branch: ModelBranch.clinicalTabular,
          score: 0.1,
          confidence: 0.05,
          status: TrainingStatus.prototypeRuleBased,
        ),
      ]);

      // Both are present, but the low-confidence branch contributes almost
      // nothing, so the result tracks the confident branch.
      expect(result.contributions, hasLength(2));
      expect(result.score, greaterThan(0.75));

      final poor = result.contributions
          .firstWhere((c) => c.branch == ModelBranch.clinicalTabular);
      expect(poor.effectiveWeight, lessThan(poor.declaredWeight),
          reason: 'effective weight must reflect measured confidence');
    });

    test('the confidence floor keeps a zero-confidence branch from vanishing', () {
      final result = fusion().fuse([
        scored(score: 0.5, confidence: 0.0),
      ]);

      expect(result.contributions, hasLength(1));
      expect(result.contributions.first.effectiveWeight, greaterThan(0));
    });
  });

  group('disagreement is surfaced as uncertainty', () {
    test('strongly disagreeing branches produce a disagreement caveat', () {
      final result = fusion().fuse([
        scored(score: 0.95, confidence: 1.0),
        scored(
          branch: ModelBranch.clinicalTabular,
          score: 0.05,
          confidence: 1.0,
          status: TrainingStatus.prototypeRuleBased,
        ),
      ]);

      expect(result.agreement, lessThan(0.6));
      expect(result.caveats.join(' ').toLowerCase(), contains('disagree'));
      expect(result.caveats.join(' ').toLowerCase(), contains('clinical review'));
    });

    test('agreeing branches report high agreement and no disagreement caveat', () {
      final result = fusion().fuse([
        scored(score: 0.5, confidence: 1.0),
        scored(
          branch: ModelBranch.clinicalTabular,
          score: 0.5,
          confidence: 1.0,
          status: TrainingStatus.prototypeRuleBased,
        ),
      ]);

      expect(result.agreement, closeTo(1.0, 1e-9));
      expect(result.caveats.join(' ').toLowerCase(), isNot(contains('disagree')));
    });

    test('a single branch reports full agreement', () {
      final result = fusion().fuse([scored(score: 0.3, confidence: 1.0)]);
      expect(result.agreement, 1.0);
    });
  });

  group('the result always carries its provenance', () {
    test('uncalibrated weights and placeholder thresholds are both disclosed', () {
      final result = fusion().fuse([scored(score: 0.5, confidence: 1.0)]);

      expect(result.isCalibrated, isFalse);
      expect(result.configProvenance.toUpperCase(), contains('UNVALIDATED'));

      final joined = result.caveats.join(' ');
      expect(joined.toLowerCase(), contains('uncalibrated'));
      expect(joined.toLowerCase(), contains('placeholder'));
    });

    test('fitted coefficients change the disclosure', () {
      const fitted = FusionConfig(
        weights: {'imu_temporal': 1.0},
        confidenceExponent: 1.0,
        calibrated: true,
        provenance: 'Fitted on the pilot cohort.',
      );

      final result = fusion(config: fitted).fuse([scored(score: 0.5, confidence: 1.0)]);

      expect(result.isCalibrated, isTrue);
      expect(result.configProvenance, 'Fitted on the pilot cohort.');
      expect(result.caveats.join(' ').toLowerCase(), isNot(contains('uncalibrated default')));
    });

    test('a placement mismatch is disclosed on the branch and in the caveats', () {
      const note = 'Trained at lumbar-L5 + dorsal foot, not thigh + shin.';
      final result = fusion().fuse([
        scored(score: 0.7, confidence: 1.0, placementNote: note),
      ]);

      expect(result.contributions.first.placementNote, note);
      expect(result.caveats.join(' '), contains('lumbar-L5'));
    });

    test('prototype-only evidence is identifiable as such', () {
      final result = fusion().fuse([
        scored(
          branch: ModelBranch.clinicalTabular,
          score: 0.6,
          confidence: 0.9,
          status: TrainingStatus.prototypeRuleBased,
        ),
      ]);

      expect(result.isPrototypeOnly, isTrue,
          reason: 'the UI must be able to say "rule-based, not a model"');
    });
  });

  group('branch honesty notices never claim validation', () {
    test('a trained score still announces that it is not clinically validated', () {
      final branch = scored(score: 0.5);
      expect(branch.honestyNotice, contains('not clinically validated'));
      expect(branch.honestyNotice.toLowerCase(), isNot(contains('validated model')));
    });

    test('an untrained branch says so plainly', () {
      final branch = unavailable(
        ModelBranch.cameraTemporal,
        BranchUnavailableReason.untrained,
      );
      expect(branch.canEnterFusion, isFalse);
      expect(branch.honestyNotice, contains('Not trained'));
    });

    test('the placement note is appended to the honesty notice when present', () {
      final branch = scored(score: 0.5, placementNote: 'Reference placement only.');
      expect(branch.honestyNotice, contains('Reference placement only.'));
    });
  });

  group('risk bands map scores to referral actions', () {
    test('scores fall into the protocol bands', () {
      expect(fusion().fuse([scored(score: 0.10, confidence: 1.0)]).band!.id, 'low');
      expect(fusion().fuse([scored(score: 0.55, confidence: 1.0)]).band!.id, 'moderate');
      expect(fusion().fuse([scored(score: 0.90, confidence: 1.0)]).band!.id, 'high');
    });

    test('the referral action comes from the band, not from a separate table', () {
      final high = fusion().fuse([scored(score: 0.95, confidence: 1.0)]);
      expect(high.referralActionKey, knee.riskLogic.bands.last.actionKey);
    });
  });

  group('Stage 1 reports coverage gaps instead of inventing markers', () {
    test('with no bundled models every joint is insufficient-data and unscored', () async {
      final localizer = Stage1Localizer(
        registry: registry,
        manifest: ModelManifest.empty,
        branchInput: const BranchInput(
          features: {},
          featureConfidence: {},
        ),
      );

      final map = await localizer.localize();

      // Six joints, two sides each.
      expect(map.markers, hasLength(12));
      expect(map.markers.every((m) => !m.isScored), isTrue);
      expect(map.markers.every((m) => m.status == RiskMarkerStatus.insufficientData), isTrue);
      expect(map.suggestedFollowUps, isEmpty);
      expect(map.hasAnyScoredMarker, isFalse);
      expect(map.unscoredJoints, hasLength(12));
      expect(map.notes.join(' '), contains('not as low risk'));
    });

    test('reported symptoms are carried separately from model output', () async {
      final localizer = Stage1Localizer(
        registry: registry,
        manifest: ModelManifest.empty,
        branchInput: const BranchInput(features: {}, featureConfidence: {}),
      );

      final map = await localizer.localize(
        reportedPain: const {'knee': ['right']},
        reportedPainScores: const {'knee': 7},
      );

      expect(map.reportedSymptoms, hasLength(1));
      expect(map.reportedSymptoms.first.region, 'knee');
      expect(map.reportedSymptoms.first.painScore, 7);
      // Serialised with an explicit source, so a symptom report can never be
      // mistaken for a model score downstream.
      expect(map.reportedSymptoms.first.toJson()['source'], 'patient_reported');
    });

    test('every joint side appears exactly once', () async {
      final localizer = Stage1Localizer(
        registry: registry,
        manifest: ModelManifest.empty,
        branchInput: const BranchInput(features: {}, featureConfidence: {}),
      );

      final map = await localizer.localize();
      final keys = map.markers.map((m) => m.key).toList();
      expect(keys.toSet(), hasLength(keys.length));
      expect(keys, contains('knee.right'));
      expect(keys, contains('knee.left'));
      expect(keys, contains('wrist.right'));
    });

    test('the follow-up threshold comes from the protocol, not from a literal', () async {
      final localizer = Stage1Localizer(
        registry: registry,
        manifest: ModelManifest.empty,
        branchInput: const BranchInput(features: {}, featureConfidence: {}),
      );

      final map = await localizer.localize();
      expect(map.followUpThreshold, knee.riskLogic.bands[1].minScore);
    });
  });

  group('the clinical prototype branch behaves like a rule, not a model', () {
    ClinicalQuestionnaire questionnaire() => knee.questionnaire;

    QuestionnaireScore scoreAll(int value) => scoreQuestionnaire(
          questionnaire(),
          {for (final item in questionnaire().items) item.id: value},
        );

    test('it labels itself as a prototype and refuses to be read as a model', () async {
      final spec = knee.modelFor(ModelBranch.clinicalTabular)!;
      final branch = ClinicalPrototypeBranch(spec: spec, protocol: knee);

      final result = await branch.score(BranchInput(
        features: const {'age': 60},
        featureConfidence: const {},
        questionnaireScore: scoreAll(2),
        modalityConfidence: const {'questionnaire': 0.95},
      ));

      expect(result.isAvailable, isTrue);
      expect(result.trainingStatus, TrainingStatus.prototypeRuleBased);
      expect(result.attributionMethod, 'feature_attribution');
      expect(result.limitations.join(' ').toLowerCase(), contains('not a fitted model'));
      expect(result.limitations.join(' ').toLowerCase(), contains('not a calibrated probability'));
    });

    test('a higher symptom burden produces a strictly higher score', () async {
      final spec = knee.modelFor(ModelBranch.clinicalTabular)!;
      final branch = ClinicalPrototypeBranch(spec: spec, protocol: knee);

      Future<double> scoreFor(int value) async {
        final r = await branch.score(BranchInput(
          features: const {'age': 60},
          featureConfidence: const {},
          questionnaireScore: scoreAll(value),
          modalityConfidence: const {'questionnaire': 1.0},
        ));
        return r.score!;
      }

      final mild = await scoreFor(1);
      final severe = await scoreFor(4);
      expect(severe, greaterThan(mild));
      expect(mild, inInclusiveRange(0.0, 1.0));
      expect(severe, inInclusiveRange(0.0, 1.0));
    });

    test('the stiffness subscale is weighted below pain and function', () async {
      final spec = knee.modelFor(ModelBranch.clinicalTabular)!;
      final branch = ClinicalPrototypeBranch(spec: spec, protocol: knee);

      // Max stiffness, zero everywhere else.
      final responses = {for (final item in questionnaire().items) item.id: 0};
      for (final item in questionnaire().itemsFor('stiffness')) {
        responses[item.id] = 4;
      }

      final stiffOnly = await branch.score(BranchInput(
        features: const {'age': 40},
        featureConfidence: const {},
        questionnaireScore: scoreQuestionnaire(questionnaire(), responses),
        modalityConfidence: const {'questionnaire': 1.0},
      ));

      final stiffnessContribution = stiffOnly.contributions
          .firstWhere((c) => c.featureKey == 'womac_stiffness');
      final painContribution =
          stiffOnly.contributions.firstWhere((c) => c.featureKey == 'womac_pain');

      expect(stiffnessContribution.contribution, greaterThan(0));
      expect(painContribution.contribution, 0);
      // The stiffness subscale carries the lowest weight because of its weaker
      // test-retest reliability, so isolated stiffness must not dominate.
      expect(stiffOnly.score, lessThan(0.2));
    });

    test('a missing feature is skipped and its weight redistributed, not zeroed', () async {
      final spec = knee.modelFor(ModelBranch.clinicalTabular)!;
      final branch = ClinicalPrototypeBranch(spec: spec, protocol: knee);

      final withAge = await branch.score(BranchInput(
        features: const {'age': 80},
        featureConfidence: const {},
        questionnaireScore: scoreAll(0),
        modalityConfidence: const {'questionnaire': 1.0},
      ));
      final withoutAge = await branch.score(BranchInput(
        features: const {},
        featureConfidence: const {},
        questionnaireScore: scoreAll(0),
        modalityConfidence: const {'questionnaire': 1.0},
      ));

      expect(withoutAge.isAvailable, isTrue);
      expect(withAge.isAvailable, isTrue);
      // All-zero symptoms and a very old patient still scores above zero,
      // because age carries weight.
      expect(withAge.score, greaterThan(0));
      // Dropping age removes that influence rather than counting it as age 40.
      expect(withoutAge.score, closeTo(0, 1e-9));
    });
  });
}
