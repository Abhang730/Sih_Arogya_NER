// Scoring tests.
//
// These pin the arithmetic to the published instrument rather than to whatever
// the current code happens to produce. If someone "simplifies" the formula, this
// fails — which matters because a wrong WOMAC total is a wrong clinical input.

import 'package:arogya_ner/domain/protocol/models.dart';
import 'package:arogya_ner/domain/protocol/scoring.dart';
import 'package:flutter_test/flutter_test.dart';

ClinicalQuestionnaire _womac() {
  QuestionnaireItem item(String id, String sub) =>
      QuestionnaireItem(id: id, subscale: sub, textKey: 'q.$id');

  return ClinicalQuestionnaire(
    instrument: 'WOMAC',
    instrumentVersion: '3.1 (Likert 5-point)',
    status: QuestionnaireStatus.specified,
    items: [
      for (var i = 1; i <= 5; i++) item('womac_pain_$i', 'pain'),
      for (var i = 1; i <= 2; i++) item('womac_stiff_$i', 'stiffness'),
      for (var i = 1; i <= 17; i++) item('womac_func_$i', 'function'),
    ],
    scoring: QuestionnaireScoring(
      responseOptions: const [
        ResponseOption(value: 0, textKey: 'none'),
        ResponseOption(value: 1, textKey: 'mild'),
        ResponseOption(value: 2, textKey: 'moderate'),
        ResponseOption(value: 3, textKey: 'severe'),
        ResponseOption(value: 4, textKey: 'extreme'),
      ],
      subscales: const [
        Subscale(name: 'pain', min: 0, max: 20),
        Subscale(name: 'stiffness', min: 0, max: 8),
        Subscale(name: 'function', min: 0, max: 68),
      ],
      totalMin: 0,
      totalMax: 96,
      direction: ScoreDirection.higherIsWorse,
      normalisation: 'percent_of_max',
      severityBands: const [],
    ),
  );
}

Map<String, int> _allZero() => {for (var i = 1; i <= 24; i++) _id(i): 0};
Map<String, int> _allFour() => {for (var i = 1; i <= 24; i++) _id(i): 4};
Map<String, int> _allTwo() => {for (var i = 1; i <= 24; i++) _id(i): 2};

String _id(int n) {
  if (n <= 5) return 'womac_pain_$n';
  if (n <= 7) return 'womac_stiff_${n - 5}';
  return 'womac_func_${n - 7}';
}

void main() {
  group('WOMAC arithmetic matches the published instrument', () {
    test('24 items scored 0 gives a total of 0 and 0% of maximum', () {
      final score = scoreQuestionnaire(_womac(), _allZero());

      expect(score.totalRaw, 0);
      expect(score.totalPercent, 0);
      expect(score.isComplete, isTrue);
      expect(score.subscale('pain')!.raw, 0);
      expect(score.subscale('stiffness')!.raw, 0);
      expect(score.subscale('function')!.raw, 0);
    });

    test('24 items scored 4 gives the maximum total of 96 and 100%', () {
      final score = scoreQuestionnaire(_womac(), _allFour());

      expect(score.totalRaw, 96);
      expect(score.totalMax, 96);
      expect(score.totalPercent, 100);
      // 5 x 4 = 20, 2 x 4 = 8, 17 x 4 = 68
      expect(score.subscale('pain')!.raw, 20);
      expect(score.subscale('stiffness')!.raw, 8);
      expect(score.subscale('function')!.raw, 68);
    });

    test('subscale maxima sum to the declared total maximum', () {
      final score = scoreQuestionnaire(_womac(), _allTwo());

      final summed = score.subscales.values
          .fold<double>(0, (sum, s) => sum + s.max);
      expect(summed, score.totalMax);

      // 24 x 2 = 48, i.e. exactly half of 96.
      expect(score.totalRaw, 48);
      expect(score.totalPercent, closeTo(50, 1e-9));
    });

    test('every item is attributed to a subscale with the right item count', () {
      final score = scoreQuestionnaire(_womac(), _allZero());

      expect(score.subscale('pain')!.itemCount, 5);
      expect(score.subscale('stiffness')!.itemCount, 2);
      expect(score.subscale('function')!.itemCount, 17);
      expect(score.itemCount, 24);
    });
  });

  group('incompleteness is reported, never papered over', () {
    test('a partially answered questionnaire is flagged incomplete and not pro-rated', () {
      // 23 of 24 items answered, all at 4.
      final partial = Map<String, int>.from(_allFour())..remove('womac_func_1');

      final score = scoreQuestionnaire(_womac(), partial);

      expect(score.isComplete, isFalse);
      expect(score.answered, 23);
      expect(score.itemCount, 24);
      expect(score.completion, closeTo(23 / 24, 1e-9));
      // Raw sum of 23 items at 4 each. Deliberately NOT scaled up to 96: naive
      // pro-rating would invent a response the patient never gave.
      expect(score.totalRaw, 92);
      expect(score.subscale('function')!.isComplete, isFalse);
      expect(score.subscale('function')!.answered, 16);
    });

    test('answering nothing at all is an error, not a zero score', () {
      expect(
        () => scoreQuestionnaire(_womac(), const {}),
        throwsA(isA<ScoringException>()),
      );
    });
  });

  group('invalid input is rejected rather than silently coerced', () {
    test('an out-of-range response value throws', () {
      final bad = _allZero()..['womac_pain_1'] = 9;
      expect(
        () => scoreQuestionnaire(_womac(), bad),
        throwsA(isA<ScoringException>()),
      );
    });

    test('a negative response value throws', () {
      final bad = _allZero()..['womac_func_3'] = -1;
      expect(
        () => scoreQuestionnaire(_womac(), bad),
        throwsA(isA<ScoringException>()),
      );
    });

    test('a questionnaire with no scoring definition cannot be scored', () {
      final unsigned = ClinicalQuestionnaire(
        instrument: 'SPADI',
        instrumentVersion: 'unspecified',
        status: QuestionnaireStatus.pendingClinicalSignOff,
        items: const [],
      );
      expect(
        () => scoreQuestionnaire(unsigned, const {}),
        throwsA(isA<ScoringException>()),
      );
      expect(unsigned.isUsable, isFalse);
    });
  });

  group('severity bands are opt-in and stay unvalidated by default', () {
    test('no bands declared means no band is attached to the score', () {
      final score = scoreQuestionnaire(_womac(), _allFour());
      expect(score.band, isNull);
    });

    test('a higher-is-worse band set resolves to the highest matching band', () {
      final withBands = _womac();
      final scoring = withBands.scoring!;
      final banded = ClinicalQuestionnaire(
        instrument: withBands.instrument,
        instrumentVersion: withBands.instrumentVersion,
        status: QuestionnaireStatus.specified,
        items: withBands.items,
        scoring: QuestionnaireScoring(
          responseOptions: scoring.responseOptions,
          subscales: scoring.subscales,
          totalMin: scoring.totalMin,
          totalMax: scoring.totalMax,
          direction: scoring.direction,
          normalisation: scoring.normalisation,
          severityBands: const [
            SeverityBand(max: 24, labelKey: 'band.mild', validated: false),
            SeverityBand(max: 48, labelKey: 'band.moderate', validated: false),
            SeverityBand(max: 96, labelKey: 'band.severe', validated: false),
          ],
        ),
      );

      expect(scoreQuestionnaire(banded, _allTwo()).band!.labelKey, 'band.moderate');
      expect(scoreQuestionnaire(banded, _allFour()).band!.labelKey, 'band.severe');
      // not validated, so the UI must still present it as configurable
      expect(banded.scoring!.hasValidatedBands, isFalse);
    });
  });
}
