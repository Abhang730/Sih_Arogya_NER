// Questionnaire scoring engine.
//
// Deliberately instrument-agnostic: the arithmetic is driven entirely by the
// protocol JSON (subscale maxima, total range, direction, normalisation). That
// is what lets a new joint ship with a new instrument and no code change, and
// it keeps the WOMAC formula in exactly one place.
//
// Verified against the published instrument: WOMAC 3.1 Likert, 24 items scored
// 0-4, pain 5 items (0-20), stiffness 2 items (0-8), function 17 items (0-68),
// total 0-96, higher is worse. tools/lint_protocols.py re-derives those maxima
// from the item list so a transcription slip fails the build rather than
// producing a quietly wrong score.

import 'models.dart';

/// Score for a single subscale (e.g. pain, stiffness, function).
class SubscaleScore {
  const SubscaleScore({
    required this.name,
    required this.raw,
    required this.min,
    required this.max,
    required this.percent,
    required this.answered,
    required this.itemCount,
  });

  final String name;
  final double raw;
  final double min;
  final double max;

  /// raw / max * 100. Useful for comparing subscales of different lengths.
  final double percent;
  final int answered;
  final int itemCount;

  bool get isComplete => answered == itemCount;
}

/// A full questionnaire result.
class QuestionnaireScore {
  const QuestionnaireScore({
    required this.instrument,
    required this.instrumentVersion,
    required this.totalRaw,
    required this.totalMin,
    required this.totalMax,
    required this.totalPercent,
    required this.subscales,
    required this.answered,
    required this.itemCount,
    required this.direction,
    this.band,
  });

  final String instrument;
  final String instrumentVersion;
  final double totalRaw;
  final double totalMin;
  final double totalMax;
  final double totalPercent;
  final Map<String, SubscaleScore> subscales;
  final int answered;
  final int itemCount;
  final ScoreDirection direction;

  /// Only populated when the protocol declares severity bands. Arogya-NER ships
  /// with none for WOMAC on purpose — inventing cut-offs would be an
  /// unvalidated clinical claim (PRD §1.2, §26.5).
  final SeverityBand? band;

  double get completion => itemCount == 0 ? 0 : answered / itemCount;

  /// A total is only meaningful when every item is answered. A partial WOMAC is
  /// reported as incomplete rather than scaled up, because naive pro-rating
  /// would invent responses the patient never gave.
  bool get isComplete => answered == itemCount && itemCount > 0;

  SubscaleScore? subscale(String name) => subscales[name];

  /// Human-readable summary used on the result screen and the report.
  String get summary {
    final parts = subscales.values
        .map((s) => '${s.name} ${_fmt(s.raw)}/${_fmt(s.max)}')
        .toList(growable: false);
    return '$instrument ${_fmt(totalRaw)}/${_fmt(totalMax)} '
        '(${totalPercent.toStringAsFixed(0)}% of maximum) — ${parts.join(', ')}';
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  Map<String, dynamic> toJson() => {
        'instrument': instrument,
        'instrument_version': instrumentVersion,
        'total_raw': totalRaw,
        'total_min': totalMin,
        'total_max': totalMax,
        'total_percent': totalPercent,
        'subscales': {
          for (final entry in subscales.entries) entry.key: entry.value.raw,
        },
        'answered': answered,
        'item_count': itemCount,
        'complete': isComplete,
        'band': band?.labelKey,
      };
}

/// Raised when a questionnaire cannot be scored at all.
class ScoringException implements Exception {
  ScoringException(this.message);

  final String message;

  @override
  String toString() => 'ScoringException: $message';
}

/// Scores [questionnaire] against [responses], where the map key is the
/// questionnaire item id and the value is the chosen response option value.
///
/// Answering nothing at all is an error (there would be no result to report at
/// all); answering some items yields an explicitly incomplete score, which the
/// UI and report must present as incomplete rather than as a total.
QuestionnaireScore scoreQuestionnaire(
  ClinicalQuestionnaire questionnaire,
  Map<String, int> responses,
) {
  final scoring = questionnaire.scoring;
  if (scoring == null) {
    throw ScoringException(
      'Questionnaire "${questionnaire.instrument}" has no scoring definition '
      '(status: ${questionnaire.status.wire}) and cannot be scored.',
    );
  }
  if (questionnaire.items.isEmpty) {
    throw ScoringException(
      'Questionnaire "${questionnaire.instrument}" has no items to score.',
    );
  }

  final permitted = scoring.responseOptions.map((o) => o.value).toSet();

  final totals = <String, double>{};
  final counts = <String, int>{};
  final answeredCounts = <String, int>{};
  for (final sub in scoring.subscales) {
    totals[sub.name] = 0;
    counts[sub.name] = 0;
    answeredCounts[sub.name] = 0;
  }

  var totalRaw = 0.0;
  var answered = 0;

  for (final item in questionnaire.items) {
    counts[item.subscale] = (counts[item.subscale] ?? 0) + 1;
    final value = responses[item.id];
    if (value == null) continue;

    if (!permitted.contains(value)) {
      throw ScoringException(
        'Response $value for item "${item.id}" is not a permitted option '
        '(${permitted.toList()..sort()}).',
      );
    }

    totals[item.subscale] = (totals[item.subscale] ?? 0) + value;
    answeredCounts[item.subscale] = (answeredCounts[item.subscale] ?? 0) + 1;
    totalRaw += value;
    answered++;
  }

  if (answered == 0) {
    throw ScoringException(
      'No responses supplied for "${questionnaire.instrument}"; nothing to score.',
    );
  }

  final subscales = <String, SubscaleScore>{};
  for (final sub in scoring.subscales) {
    final raw = totals[sub.name] ?? 0;
    subscales[sub.name] = SubscaleScore(
      name: sub.name,
      raw: raw,
      min: sub.min,
      max: sub.max,
      percent: sub.max <= 0 ? 0 : (raw / sub.max) * 100,
      answered: answeredCounts[sub.name] ?? 0,
      itemCount: counts[sub.name] ?? 0,
    );
  }

  final span = scoring.totalMax - scoring.totalMin;
  final totalPercent = span <= 0 ? 0.0 : ((totalRaw - scoring.totalMin) / span) * 100;

  return QuestionnaireScore(
    instrument: questionnaire.instrument,
    instrumentVersion: questionnaire.instrumentVersion,
    totalRaw: totalRaw,
    totalMin: scoring.totalMin,
    totalMax: scoring.totalMax,
    totalPercent: totalPercent.clamp(0, 100).toDouble(),
    subscales: subscales,
    answered: answered,
    itemCount: questionnaire.items.length,
    direction: scoring.direction,
    band: _bandFor(scoring, totalRaw),
  );
}

SeverityBand? _bandFor(QuestionnaireScoring scoring, double raw) {
  if (scoring.severityBands.isEmpty) return null;

  // Bands are declared as an upper bound ("max"), ascending. Highest score wins
  // the highest band, which is correct for a higher-is-worse instrument; a
  // higher-is-better instrument would need its bands inverted, so that case is
  // rejected rather than silently mis-scored.
  if (scoring.direction != ScoreDirection.higherIsWorse) return null;

  final sorted = [...scoring.severityBands]..sort((a, b) => a.max.compareTo(b.max));
  for (final band in sorted) {
    if (raw <= band.max) return band;
  }
  return sorted.last;
}
