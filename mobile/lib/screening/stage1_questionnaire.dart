// Stage-1 whole-body questionnaire (PRD §8).
//
// PRD §8.2–§8.6 define five sections: body pain map, general mobility, NER
// occupational exposure, basic medical history and a symptom scale.
//
// Two things about this file are deliberate:
//
//   * The pain map is NOT hard-coded. It is rendered from
//     ProtocolRegistry.bodyMapRegions, which comes from protocols/index.json.
//     That is what keeps the body map and the joint list from drifting apart:
//     a new joint adds a region and the questionnaire follows (PRD §12.1, §29).
//   * This instrument is app content, not a licensed clinical instrument, so it
//     lives in the ordinary string tables. Only a validated instrument (WOMAC,
//     SPADI, …) is governed by [ClinicalStrings], and only that one is blocked
//     on clinical sign-off (DECISIONS.md D5).

import '../data/records.dart';

/// A three-way answer, because "I don't know" is a real and different answer
/// from "no". Collapsing it to false would turn an unknown into a negative.
enum TriAnswer {
  no('no'),
  yes('yes'),
  unsure('unsure');

  const TriAnswer(this.wire);

  final String wire;

  static TriAnswer? fromWire(String? v) =>
      TriAnswer.values.where((a) => a.wire == v).firstOrNull;
}

/// One yes/no/unsure item in sections B, C or D.
class Stage1Item {
  const Stage1Item({
    required this.id,
    required this.section,
    required this.labelKey,
    this.riskWeight = 1,
  });

  final String id;
  final Stage1Section section;
  final String labelKey;

  /// Documented heuristic weight, used only by [stage1ReportedBurden] to order
  /// the evidence summary. It never enters a model — there is no trained Stage-1
  /// model (see ai/stage1_localizer.dart) — so it must not be presented as one.
  final int riskWeight;
}

enum Stage1Section {
  painMap('pain_map'),
  mobility('mobility'),
  exposure('exposure'),
  history('history'),
  symptom('symptom');

  const Stage1Section(this.wire);

  final String wire;
}

class Stage1Instrument {
  const Stage1Instrument._();

  /// Bump on any change to the item set below.
  static const String version = '2026.09.1';

  static const List<Stage1Item> mobilityItems = [
    Stage1Item(
      id: 'mobility.rise',
      section: Stage1Section.mobility,
      labelKey: 'questionnaire.mobility.rise',
      riskWeight: 2,
    ),
    Stage1Item(
      id: 'mobility.stairs',
      section: Stage1Section.mobility,
      labelKey: 'questionnaire.mobility.stairs',
      riskWeight: 2,
    ),
    Stage1Item(
      id: 'mobility.walk',
      section: Stage1Section.mobility,
      labelKey: 'questionnaire.mobility.walk',
      riskWeight: 2,
    ),
    Stage1Item(
      id: 'mobility.dressing',
      section: Stage1Section.mobility,
      labelKey: 'questionnaire.mobility.dressing',
    ),
  ];

  /// PRD §8.4 — the exposure profile that is specific to the North Eastern
  /// Region. These fields are the product's differentiation, so they are first
  /// class rather than an optional extra.
  static const List<Stage1Item> exposureItems = [
    Stage1Item(
      id: 'exposure.kneeling',
      section: Stage1Section.exposure,
      labelKey: 'questionnaire.exposure.kneeling',
      riskWeight: 2,
    ),
    Stage1Item(
      id: 'exposure.loading',
      section: Stage1Section.exposure,
      labelKey: 'questionnaire.exposure.loading',
      riskWeight: 2,
    ),
    Stage1Item(
      id: 'exposure.terrain',
      section: Stage1Section.exposure,
      labelKey: 'questionnaire.exposure.terrain',
    ),
    Stage1Item(
      id: 'exposure.hours',
      section: Stage1Section.exposure,
      labelKey: 'questionnaire.exposure.hours',
    ),
  ];

  static const List<Stage1Item> historyItems = [
    Stage1Item(
      id: 'history.injury',
      section: Stage1Section.history,
      labelKey: 'questionnaire.history.injury',
      riskWeight: 2,
    ),
    Stage1Item(
      id: 'history.arthritis',
      section: Stage1Section.history,
      labelKey: 'questionnaire.history.arthritis',
      riskWeight: 2,
    ),
    Stage1Item(
      id: 'history.diabetes',
      section: Stage1Section.history,
      labelKey: 'questionnaire.history.diabetes',
    ),
    Stage1Item(
      id: 'history.medication',
      section: Stage1Section.history,
      labelKey: 'questionnaire.history.medication',
    ),
  ];

  /// Every binary item, in presentation order.
  static List<Stage1Item> get allItems =>
      [...mobilityItems, ...exposureItems, ...historyItems];

  /// Total considered "answered" for completion purposes. The pain map and the
  /// symptom scale are counted separately because a patient with no pain
  /// legitimately selects nothing in the pain map, and that must not read as an
  /// incomplete questionnaire.
  static int get binaryItemCount => allItems.length;
}

/// One patient's Stage-1 answers.
class Stage1Answers {
  Stage1Answers({
    Map<String, TriAnswer>? binary,
    Map<String, Set<String>>? painRegions,
    this.painScore,
  })  : binary = binary ?? <String, TriAnswer>{},
        painRegions = painRegions ?? <String, Set<String>>{};

  /// Item id to answer.
  final Map<String, TriAnswer> binary;

  /// Region id to affected sides. Empty means no pain reported, which is a
  /// valid and complete answer.
  final Map<String, Set<String>> painRegions;

  /// 0–10 worst pain in the last 24 hours (PRD §8.6).
  final double? painScore;

  bool isAnswered(String itemId) => binary.containsKey(itemId);

  int get answeredCount => binary.length;

  bool get isComplete => answeredCount == Stage1Instrument.binaryItemCount;

  double get completion => Stage1Instrument.binaryItemCount == 0
      ? 0
      : answeredCount / Stage1Instrument.binaryItemCount;

  /// Regions with reported pain, as `region -> sides` for the localiser.
  Map<String, List<String>> get reportedPain => {
        for (final entry in painRegions.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value.toList(growable: false),
      };

  /// The current symptom scale, applied to every region with reported pain.
  ///
  /// Empty when no symptom scale was recorded, so a localiser cannot mistake an
  /// absent scale for a measured zero (PRD §26.5).
  Map<String, double> get reportedPainScores {
    final score = painScore;
    if (score == null) return const {};
    return {
      for (final region in painRegions.keys) region: score,
    };
  }

  /// A documented, unvalidated burden index over the yes-answers.
  ///
  /// This is NOT a model output and is never fused as one. It exists so the
  /// result screen can order the reported evidence, and it is labelled as a
  /// symptom summary wherever it appears (PRD §26.5).
  double get reportedBurden {
    if (binary.isEmpty) return 0;
    var weighted = 0.0;
    var possible = 0;
    for (final item in Stage1Instrument.allItems) {
      possible += item.riskWeight;
      switch (binary[item.id]) {
        case TriAnswer.yes:
          weighted += item.riskWeight;
        case TriAnswer.unsure:
          // Counts as half: pretending certainty in either direction would be
          // inventing information the patient did not give.
          weighted += item.riskWeight / 2;
        case TriAnswer.no:
        case null:
          break;
      }
    }
    return possible == 0 ? 0 : (weighted / possible).clamp(0.0, 1.0);
  }

  /// Confidence in the questionnaire as a modality input, from answered
  /// fraction. Deliberately capped below 1: a self-reported instrument is never
  /// as trustworthy as a measured signal, and fusion weights it accordingly.
  double get confidence {
    if (!isComplete) return completion * 0.7;
    return 0.7 + 0.2 * (painScore == null ? 0.0 : 1.0);
  }

  Map<String, Object?> toJson() => {
        'instrument_version': Stage1Instrument.version,
        'binary': {
          for (final entry in binary.entries) entry.key: entry.value.wire,
        },
        'pain_regions': {
          for (final entry in painRegions.entries)
            entry.key: entry.value.toList(growable: false),
        },
        'pain_score_0_10': painScore,
        'answered_count': answeredCount,
        'required_count': Stage1Instrument.binaryItemCount,
        'complete': isComplete,
        'reported_burden_index': reportedBurden,
        'burden_is_model_output': false,
      };
}

/// Derived demographic and anthropometric inputs the clinical branch consumes.
///
/// Kept as its own object because these are the only Stage-1 values that reach a
/// scoring branch, and a rule that cannot find its input must be visibly skipped
/// rather than defaulted (see ai/clinical_branch.dart).
Map<String, double> clinicalInputsFrom(Patient patient) {
  final inputs = <String, double>{};
  if (patient.ageYears != null) inputs['age'] = patient.ageYears!.toDouble();

  final weight = patient.weightKg;
  final height = patient.heightCm;
  if (weight != null && height != null && height > 0) {
    final metres = height / 100.0;
    final bmi = weight / (metres * metres);
    if (bmi.isFinite && bmi > 0) inputs['bmi'] = bmi;
  }
  return inputs;
}
