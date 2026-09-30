// Stage-1 body risk map (PRD §11, §10.5, §32.5 step 5).
//
// PRD §6.2 is explicit that this stage answers "WHERE should we investigate",
// and §11.2 keeps human confirmation in the loop. So this screen never selects a
// joint for the worker: it ranks candidates and the worker confirms.
//
// The presentation rule that matters most here: a joint with no model is shown
// as "not assessed", never as low risk. Blank space would read as "fine", and
// "fine" is a claim this stage cannot make (PRD §26.5).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../ai/stage1_localizer.dart';
import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../widgets/common.dart';

class BodyRiskMapScreen extends ConsumerWidget {
  const BodyRiskMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(screeningSessionProvider);
    final riskMap = session.stage1RiskMap;
    final s = context.strings;

    if (riskMap == null) {
      return Scaffold(
        appBar: AppBar(title: Text(s.t('risk.title'))),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: MessageCard(
            severity: MessageSeverity.error,
            message: 'No Stage-1 result is in this session. Complete the '
                'whole-body screen first.',
          ),
        ),
      );
    }

    final suggested = riskMap.suggestedFollowUps;
    final scored = riskMap.markers.where((m) => m.isScored).toList(growable: false);
    final unscored = riskMap.unscoredJoints;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('risk.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (session.stage1Synthetic) ...[
            SyntheticDataNotice(
              message: 'This body map is derived from SIMULATED landmarks '
                  '(${session.stage1PoseEngineId ?? 'unknown engine'}). Nothing '
                  'below is a measurement of this patient.',
            ),
            const SizedBox(height: 10),
          ],

          SectionCard(
            title: s.t('risk.suggested'),
            subtitle: suggested.isEmpty
                ? s.t('risk.none_suggested')
                : 'These joints were scored above the follow-up threshold. '
                    'Confirm or override the target — the choice stays with the '
                    'worker (PRD §11.2).',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (suggested.isEmpty)
                  const MessageCard(
                    message: 'No trained Stage-1 model is available, so no joint '
                        'marker could be scored. Patient-reported pain below is '
                        'still valid evidence and can be used to choose a joint.',
                  ),
                for (final marker in suggested)
                  _MarkerTile(marker: marker, onTap: () => _select(context, ref, marker)),
              ],
            ),
          ),

          if (riskMap.reportedSymptoms.isNotEmpty)
            SectionCard(
              title: s.t('risk.reported_pain'),
              subtitle: 'Patient-reported, not a model output.',
              child: Column(
                children: [
                  for (final symptom in riskMap.reportedSymptoms)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_pin_circle_outlined),
                      title: Text(symptom.region),
                      subtitle: Text(
                        'Sides: ${symptom.sides.join(', ')}'
                        '${symptom.painScore == null ? ' · symptom scale not recorded' : ' · ${symptom.painScore!.round()}/10'}',
                      ),
                      trailing: _selectButton(context, ref, symptom.region, symptom.sides),
                    ),
                ],
              ),
            ),

          SectionCard(
            title: 'All joint markers',
            subtitle: s.t('risk.coverage_note'),
            child: Column(
              children: [
                for (final marker in scored)
                  _MarkerTile(marker: marker, onTap: () => _select(context, ref, marker)),
                if (unscored.isNotEmpty) ...[
                  const Divider(height: 24),
                  for (final marker in unscored.take(12))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(
                        RiskPresentation.notAssessed.icon,
                        color: RiskPresentation.notAssessed.color,
                      ),
                      title: Text('${marker.jointId} · ${marker.side}'),
                      subtitle: Text(
                        marker.caveats.isEmpty
                            ? RiskMarkerStatus.insufficientData.explanation
                            : marker.caveats.first,
                      ),
                      trailing: _selectButton(context, ref, marker.jointId, [marker.side]),
                    ),
                ],
              ],
            ),
          ),

          MessageCard(
            message: riskMap.notes.join('\n\n'),
            severity: MessageSeverity.info,
          ),

          const SizedBox(height: 20),
          const SafetyBanner(dense: true),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// The worker's confirmation step. A joint the model did not flag is still
  /// selectable, because a patient can report pain the model had no data to
  /// score (PRD §11.3).
  void _select(BuildContext context, WidgetRef ref, JointRiskMarker marker) {
    ref.read(screeningSessionProvider.notifier).selectJoint(
          jointId: marker.jointId,
          side: marker.side,
        );
    context.go('/joint');
  }

  Widget? _selectButton(
    BuildContext context,
    WidgetRef ref,
    String jointId,
    List<String> sides,
  ) {
    final registry = ref.watch(registryProvider).value;
    if (registry == null || !registry.hasJoint(jointId)) return null;
    final side = sides.contains('right') ? 'right' : sides.first;

    return TextButton(
      onPressed: () {
        ref.read(screeningSessionProvider.notifier)
            .selectJoint(jointId: jointId, side: side);
        context.go('/joint');
      },
      child: Text(context.s('risk.select_joint')),
    );
  }
}

class _MarkerTile extends StatelessWidget {
  const _MarkerTile({required this.marker, required this.onTap});

  final JointRiskMarker marker;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.accessibility_new),
      title: Text('${marker.jointId} · ${marker.side}'),
      subtitle: Text(
        'Score ${marker.score!.toStringAsFixed(2)} · '
        'confidence ${(marker.confidence * 100).round()}%'
        '${marker.modelVersion == null ? '' : ' · model ${marker.modelVersion}'}',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
      ),
      trailing: TextButton(
        onPressed: onTap,
        child: Text(context.s('risk.select_joint')),
      ),
    );
  }
}
