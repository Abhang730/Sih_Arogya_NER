// Stage-1 whole-body questionnaire (PRD §8, §9, §28 FR-06, §32.5 step 3).
//
// Renders in five sections over one scrolling screen rather than a wizard, so a
// worker can see how much is left and move back without losing answers.
//
// The pain map is built from ProtocolRegistry.bodyMapRegions — from
// protocols/index.json, not from a hard-coded list — which is what keeps the
// body map and the joint list from drifting apart (PRD §11.1, §12.1).
//
// Allergic to free text (PRD §19.2 "very little free-text entry"): every item is
// a tap target, and the only two numeric entries are the 0–10 symptom scale and
// nothing else.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../domain/protocol/registry.dart';
import '../../screening/stage1_questionnaire.dart';
import '../widgets/common.dart';

class QuestionnaireScreen extends ConsumerStatefulWidget {
  const QuestionnaireScreen({super.key});

  @override
  ConsumerState<QuestionnaireScreen> createState() =>
      _QuestionnaireScreenState();
}

class _QuestionnaireScreenState extends ConsumerState<QuestionnaireScreen> {
  final _binary = <String, TriAnswer>{};
  final _pain = <String, Set<String>>{};
  double? _painScore;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final registryAsync = ref.watch(registryProvider);
    final session = ref.watch(screeningSessionProvider);

    return Scaffold(
      appBar: AppBar(title: Text(s.t('questionnaire.title'))),
      body: registryAsync.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(error: error),
        data: (registry) {
          final answered = _binary.length;
          final total = Stage1Instrument.binaryItemCount;

          return Column(
            children: [
              LinearProgressIndicator(
                value: total == 0 ? 1 : answered / total,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.tArgs('questionnaire.progress', {
                          'answered': '$answered',
                          'total': '$total',
                        }),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (session.patient != null)
                      Text(
                        session.patient!.arogyaPatientId,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _painMapSection(registry, s),
                    _binarySection(
                      s.t('questionnaire.section.mobility'),
                      Stage1Instrument.mobilityItems,
                      s,
                    ),
                    _binarySection(
                      s.t('questionnaire.section.exposure'),
                      Stage1Instrument.exposureItems,
                      s,
                      note: 'These fields are specific to the North Eastern '
                          'Region and are treated as first-class screening '
                          'context, not an optional extra.',
                    ),
                    _binarySection(
                      s.t('questionnaire.section.history'),
                      Stage1Instrument.historyItems,
                      s,
                    ),
                    _symptomSection(s),
                    if (_error != null)
                      MessageCard(message: _error!, severity: MessageSeverity.error),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => _save(registry),
                      child: Text(s.t('action.next')),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _painMapSection(ProtocolRegistry registry, AppStrings s) {
    final assessable =
        registry.bodyMapRegions.where((r) => r.sides.isNotEmpty).toList();

    return SectionCard(
      title: s.t('questionnaire.section.pain'),
      subtitle: s.t('questionnaire.pain_hint'),
      child: Column(
        children: [
          for (final region in assessable)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_regionLabel(region, s)),
                  ),
                  for (final side in region.sides)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: FilterChip(
                        label: Text(
                          side == 'left'
                              ? 'L'
                              : side == 'right'
                                  ? 'R'
                                  : side,
                        ),
                        selected: _pain[region.region]?.contains(side) ?? false,
                        onSelected: (_) => setState(() {
                          final sides = _pain.putIfAbsent(region.region, () => <String>{});
                          if (!sides.remove(side)) sides.add(side);
                          if (sides.isEmpty) _pain.remove(region.region);
                        }),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Region labels come from the registry's label keys, with a readable
  /// fallback derived from the region id so a new region never renders blank.
  static String _regionLabel(BodyMapRegion region, AppStrings s) {
    final fromTable = s.t(region.labelKey);
    if (fromTable != region.labelKey) return fromTable;
    return region.region
        .split('_')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  Widget _binarySection(
    String title,
    List<Stage1Item> items,
    AppStrings s, {
    String? note,
  }) {
    return SectionCard(
      title: title,
      subtitle: note,
      child: Column(
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_itemLabel(item, s), style: const TextStyle(fontSize: 14.5)),
                  const SizedBox(height: 6),
                  SegmentedButton<TriAnswer>(
                    segments: [
                      ButtonSegment(
                        value: TriAnswer.no,
                        label: Text(s.t('questionnaire.answer.no')),
                      ),
                      ButtonSegment(
                        value: TriAnswer.yes,
                        label: Text(s.t('questionnaire.answer.yes')),
                      ),
                      ButtonSegment(
                        value: TriAnswer.unsure,
                        label: Text(s.t('questionnaire.answer.unsure')),
                      ),
                    ],
                    selected: {
                      if (_binary[item.id] != null) _binary[item.id]!,
                    },
                    emptySelectionAllowed: true,
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) => setState(() {
                      if (selection.isEmpty) {
                        _binary.remove(item.id);
                      } else {
                        _binary[item.id] = selection.first;
                      }
                    }),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _itemLabel(Stage1Item item, AppStrings s) {
    final value = s.t(item.labelKey);
    return value == item.labelKey ? item.id : value;
  }

  Widget _symptomSection(AppStrings s) {
    final score = _painScore;
    return SectionCard(
      title: s.t('questionnaire.section.symptom'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.t('questionnaire.pain_score')),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: score ?? 0,
                  max: 10,
                  divisions: 10,
                  label: score == null ? 'not recorded' : score.round().toString(),
                  onChanged: (value) => setState(() => _painScore = value),
                ),
              ),
              SizedBox(
                width: 74,
                child: Text(
                  score == null ? 'not set' : '${score.round()} / 10',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontStyle: score == null ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ),
            ],
          ),
          if (score == null)
            const MessageCard(
              message: 'The symptom scale is optional and is recorded as not '
                  'measured if left unset. It is never stored as zero.',
            ),
        ],
      ),
    );
  }

  void _save(ProtocolRegistry registry) {
    final answers = Stage1Answers(
      binary: _binary,
      painRegions: _pain,
      painScore: _painScore,
    );

    if (!answers.isComplete) {
      setState(() => _error =
          'Answer every question before continuing — ${answers.answeredCount} of '
          '${Stage1Instrument.binaryItemCount} answered. A partial questionnaire '
          'is not scored.');
      return;
    }

    ref.read(screeningSessionProvider.notifier).setAnswers(answers);
    if (mounted) context.go('/screen');
  }
}
