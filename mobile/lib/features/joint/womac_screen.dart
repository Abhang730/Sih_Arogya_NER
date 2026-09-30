// Joint questionnaire (PRD §12, §28 FR-12, DECISIONS.md D5/D6).
//
// The instrument, its items, its response options and its arithmetic all come
// from the selected joint's protocol — this file contains no WOMAC-specific
// logic, so a future SPADI or FAAM needs no code change.
//
// Two decisions from docs/DECISIONS.md are visible on screen and are deliberate:
//
//   * D5 — instrument Wording is NOT transcribed until clinical sign-off. The
//     canonical wording is licensed. So items render by their localisation key
//     with a clear notice, rather than by invented paraphrases. The alternative
//     would be paraphrasing a licensed clinical instrument, which is a clinical
//     governance decision, not an engineering one.
//   * D6 — no severity bands are invented. WOMAC ships with `severity_bands`
//     empty, so a total is reported as a number out of its maximum and never
//     bucketed into "mild/moderate/severe". The score screen says so.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../domain/protocol/models.dart';
import '../../domain/protocol/scoring.dart';
import '../widgets/common.dart';

class WomacScreen extends ConsumerStatefulWidget {
  const WomacScreen({super.key});

  @override
  ConsumerState<WomacScreen> createState() => _WomacScreenState();
}

class _WomacScreenState extends ConsumerState<WomacScreen> {
  final Map<String, int> _responses = {};
  String? _error;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(screeningSessionProvider);
    final jointId = session.jointId;
    final s = context.strings;

    if (jointId == null) {
      return Scaffold(
        appBar: AppBar(title: Text(s.t('womac.title'))),
        body: const Padding(
          padding: EdgeInsets.all(20),
          child: MessageCard(
            severity: MessageSeverity.error,
            message: 'No joint is selected.',
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('${s.t('womac.title')} · $jointId')),
      body: ref.watch(registryProvider).when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(error: error),
        data: (registry) {
          final questionnaire = registry.protocolFor(jointId).questionnaire;
          final scoring = questionnaire.scoring;

          if (!questionnaire.isUsable || scoring == null) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: MessageCard(
                severity: MessageSeverity.warning,
                message: s.t('joint.questionnaire_unavailable'),
              ),
            );
          }

          QuestionnaireScore? score;
          try {
            score = _responses.isEmpty
                ? null
                : scoreQuestionnaire(questionnaire, _responses);
          } on ScoringException catch (error) {
            score = null;
            _error = error.message;
          }

          final subscales = scoring.subscales.map((sub) => sub.name).toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                title: '${questionnaire.instrument} '
                    '${questionnaire.instrumentVersion}',
                subtitle: s.t('womac.intro'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (ClinicalStrings.isInstrumentWordingPending())
                      const MessageCard(
                        severity: MessageSeverity.warning,
                        title: 'Item wording pending clinical sign-off',
                        message: 'The canonical instrument wording is licensed '
                            'and is not transcribed into the app until the '
                            'deployment authority approves it (DECISIONS.md D5). '
                            'Items are shown by their localisation key. The '
                            'scoring arithmetic is implemented exactly as '
                            'published and is verified against the item list by '
                            'tools/lint_protocols.py.',
                      ),
                    if (questionnaire.licenceNote != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        questionnaire.licenceNote!,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ],
                ),
              ),

              for (final subscale in subscales)
                SectionCard(
                  title: subscale,
                  subtitle: '${questionnaire.itemsFor(subscale).length} items',
                  child: Column(
                    children: [
                      for (final item in questionnaire.itemsFor(subscale))
                        _ItemRow(
                          item: item,
                          options: scoring.responseOptions,
                          selected: _responses[item.id],
                          onSelect: (value) => setState(() {
                            if (value == null) {
                              _responses.remove(item.id);
                            } else {
                              _responses[item.id] = value;
                            }
                          }),
                        ),
                    ],
                  ),
                ),

              SectionCard(
                title: 'Score',
                child: score == null
                    ? const Text('Answer at least one item to see a score.')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!score.isComplete)
                            MessageCard(
                              severity: MessageSeverity.warning,
                              message: s.tArgs('womac.incomplete', {
                                'answered': '${score.answered}',
                                'total': '${score.itemCount}',
                              }),
                            ),
                          Text(
                            score.summary,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final sub in score.subscales.values)
                            MeasurementTile(
                              label: sub.name,
                              value: sub.raw,
                              unit: '/ ${sub.max.toInt()}',
                              caveat: sub.isComplete
                                  ? null
                                  : 'incomplete (${sub.answered}/${sub.itemCount})',
                            ),
                          const Divider(height: 22),
                          Text(
                            score.band == null
                                ? 'No severity band is declared for this '
                                    'instrument, so none is shown. There is no '
                                    'universally accepted cut-off and inventing '
                                    'one would be an unvalidated clinical claim '
                                    '(DECISIONS.md D6).'
                                : 'Band: ${score.band!.labelKey}'
                                    '${score.band!.validated ? '' : ' (configurable bucket, not a clinical cut-off)'}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
              ),

              if (_error != null)
                MessageCard(message: _error!, severity: MessageSeverity.error),

              const SizedBox(height: 8),
              FilledButton(
                onPressed: score == null || !score.isComplete
                    ? null
                    : () {
                        ref
                            .read(screeningSessionProvider.notifier)
                            .setQuestionnaireScore(score!);
                        context.pop();
                      },
                child: Text(s.t('action.save')),
              ),
              const SizedBox(height: 24),
              const SafetyBanner(dense: true),
            ],
          );
        },
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final QuestionnaireItem item;
  final List<ResponseOption> options;
  final int? selected;
  final ValueChanged<int?> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.id,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final option in options)
                ChoiceChip(
                  label: Text('${option.value}'),
                  selected: selected == option.value,
                  onSelected: (isSelected) =>
                      onSelect(isSelected ? option.value : null),
                ),
            ],
          ),
          if (selected == null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'not answered',
                style: TextStyle(
                  fontSize: 11.5,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
