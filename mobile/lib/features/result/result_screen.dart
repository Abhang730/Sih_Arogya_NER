// Joint screening result (PRD §18, §24.2, §32.5 step 8) and the
// screening-not-diagnosis boundary (PRD §1.2, §28 FR-25).
//
// Three presentation rules from the PRD are enforced here, and none of them is a
// cosmetic choice:
//
//   * §19.2 — risk state is never conveyed by colour alone. Every band goes
//     through RiskPresentation, which carries an icon and a word.
//   * §19.2 — a failed quality check is never hidden. Every branch that could
//     not contribute is listed with the reason it could not, and every caveat
//     raised upstream is rendered rather than summarised away.
//   * §26.5 — a missing measurement is not a zero. A fusion with no score shows
//     "no combined indication", not 0%.
//
// The disclaimer is a clinical string (lib/app/safety.dart pulls it from
// ClinicalStrings), not interface copy, and it is rendered by SafetyBanner and
// SafetyFooter rather than by a bare Text widget, so a future screen cannot
// forget it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../ai/branch.dart';
import '../../ai/fusion.dart';
import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../app/theme.dart';
import '../../data/records.dart';
import '../widgets/common.dart';

class ResultScreen extends ConsumerStatefulWidget {
  const ResultScreen({super.key});

  @override
  ConsumerState<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends ConsumerState<ResultScreen> {
  bool _finishing = false;
  String? _error;

  Future<void> _finish() async {
    setState(() {
      _finishing = true;
      _error = null;
    });

    try {
      final session = ref.read(screeningSessionProvider);
      final screeningId = session.screening?.screeningId;
      final workerId = ref.read(authProvider)?.workerId;

      if (screeningId != null) {
        final repos = await ref.read(repositoriesProvider.future);
        await repos.screenings.updateStatus(
          screeningId,
          ScreeningStatus.completed,
          actor: workerId,
        );
        // Queued rather than uploaded: this device is offline-first, and a
        // completed screening must never wait on a network to be recorded
        // (PRD §18.1, FR-20).
        await repos.screenings.enqueueForSync(screeningId);
      }

      ref.read(screeningSessionProvider.notifier).reset();
      if (mounted) context.go('/home');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _finishing = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final session = ref.watch(screeningSessionProvider);
    final outcome = session.jointOutcome;

    if (outcome == null) {
      return Scaffold(
        appBar: AppBar(title: Text(s.t('result.title'))),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MessageCard(
                severity: MessageSeverity.error,
                message: 'This session has no joint assessment yet, so there is '
                    'no result to show.',
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/home'),
                child: Text(s.t('home.title')),
              ),
            ],
          ),
        ),
      );
    }

    final fusion = outcome.fusion;
    final presentation = RiskPresentation.forBand(fusion.band);

    return Scaffold(
      appBar: AppBar(title: Text(s.t('result.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SafetyBanner(),
          const SizedBox(height: 10),

          if (session.usedSimulatedData)
            SyntheticDataNotice(
              message: 'Part of this assessment used SIMULATED data '
                  '(${session.stage1PoseEngineId ?? 'synthetic engine'}). It is '
                  'a demonstration of the workflow, not a measurement of this '
                  'patient, and it is stored and reported as synthetic.',
            ),

          SectionCard(
            title: s.t('result.indication'),
            subtitle: '${outcome.jointId} · ${outcome.side} · protocol '
                '${outcome.protocolVersion}',
            trailing: RiskChip(presentation: presentation),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!fusion.hasScore)
                  MessageCard(
                    message: s.t('result.no_score'),
                    severity: MessageSeverity.warning,
                  )
                else
                  MeasurementTile(
                    label: 'Combined screening index',
                    value: fusion.score! * 100,
                    unit: '%',
                    caveat: fusion.isCalibrated
                        ? 'Calibrated on held-out validation data.'
                        : 'Uncalibrated index for triage ordering only — not a '
                            'probability of disease.',
                  ),
                if (fusion.hasScore && fusion.contributions.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      s.tArgs('result.agreement', {
                        'percent': '${(fusion.agreement * 100).round()}',
                      }),
                    ),
                  ),
                if (!fusion.isCalibrated) ...[
                  const SizedBox(height: 8),
                  MessageCard(
                    message: fusion.configProvenance,
                    severity: MessageSeverity.warning,
                    title: 'Not calibrated',
                  ),
                ],
                if (fusion.isPrototypeOnly) ...[
                  const SizedBox(height: 8),
                  const MessageCard(
                    message: 'Every contributing score came from a rule-based '
                        'prototype, not from a trained model. Treat this as a '
                        'structured opinion, not as model output.',
                    severity: MessageSeverity.warning,
                  ),
                ],
              ],
            ),
          ),

          SectionCard(
            title: s.t('result.referral'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _actionLabel(fusion.referralActionKey),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'This is a screening recommendation produced from the '
                  'evidence below. It is not a diagnosis and it does not replace '
                  'a clinician\'s judgement about what this patient needs.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          SectionCard(
            title: s.t('result.contributors'),
            subtitle: fusion.contributions.isEmpty
                ? 'No branch was able to contribute a score.'
                : 'Ordered by how much each branch moved the result.',
            child: Column(
              children: [
                for (final contribution in fusion.contributions)
                  _ContributionTile(contribution: contribution),
              ],
            ),
          ),

          SectionCard(
            title: s.t('result.not_contributing'),
            subtitle: 'Shown rather than omitted: an unexplained missing '
                'measurement is indistinguishable from a bug.',
            child: Column(
              children: [
                for (final branch in fusion.allBranches.where((b) => !b.isAvailable))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.remove_circle_outline,
                      color: RiskPresentation.notAssessed.color,
                    ),
                    title: Text(branch.branch.displayName),
                    subtitle: Text(
                      branch.reason?.explanation ?? 'Unavailable.',
                    ),
                  ),
              ],
            ),
          ),

          SectionCard(
            title: 'Measurements taken',
            child: Column(
              children: [
                MeasurementTile(
                  label: 'Camera capture confidence',
                  value: outcome.cameraConfidence * 100,
                  unit: '%',
                  caveat: outcome.cameraConfidence < 0.5
                      ? 'Low: camera-derived components are indicative only.'
                      : null,
                ),
                MeasurementTile(
                  label: 'Motion Pod placements recorded',
                  value: outcome.sensorPlacement == null ? null : 1,
                  caveat: outcome.sensorPlacement == null
                      ? 'No pod trial was recorded for this assessment.'
                      : '${outcome.sensorPlacement} — the model was trained at a '
                          'different rig (DECISIONS.md D3).',
                ),
                if (outcome.questionnaire != null) ...[
                  const Divider(height: 24),
                  Text(
                    outcome.questionnaire!.summary,
                    style: const TextStyle(fontSize: 14, height: 1.4),
                  ),
                  const SizedBox(height: 6),
                  for (final sub in outcome.questionnaire!.subscales.values)
                    MeasurementTile(
                      label: sub.name,
                      value: sub.raw,
                      unit: '/ ${sub.max.toInt()}',
                      caveat: sub.isComplete
                          ? null
                          : 'incomplete (${sub.answered}/${sub.itemCount})',
                    ),
                ] else
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'No joint questionnaire was completed for this screening.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                if (outcome.imuFeatures.isNotEmpty) ...[
                  const Divider(height: 24),
                  MeasurementTile(
                    label: 'Pod signal quality',
                    value: (outcome.imuFeatures['imu_signal_quality'] ?? 0) * 100,
                    unit: '%',
                  ),
                  MeasurementTile(
                    label: 'Proximal–distal correlation',
                    value: outcome.imuFeatures['imu_proximal_distal_correlation'],
                  ),
                ],
              ],
            ),
          ),

          if (outcome.caveats.isNotEmpty)
            SectionCard(
              title: 'Everything a reader must know',
              subtitle: '${outcome.caveats.length} caveat'
                  '${outcome.caveats.length == 1 ? '' : 's'} raised during this '
                  'assessment.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final caveat in outcome.caveats)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline, size: 17),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              caveat,
                              style: const TextStyle(fontSize: 13, height: 1.35),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

          SectionCard(
            title: s.t('result.model_versions'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in _modelVersions(fusion.allBranches).entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(entry.key),
                    subtitle: Text(entry.value),
                  ),
                const Divider(height: 20),
                Text(
                  fusion.configProvenance,
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
              ],
            ),
          ),

          if (_error != null)
            MessageCard(message: _error!, severity: MessageSeverity.error),

          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => context.push('/report'),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: Text(s.t('report.title')),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _finishing ? null : _finish,
            child: _finishing
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('FINISH SCREENING'),
          ),

          const SizedBox(height: 20),
          const SafetyFooter(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Plain-language next step for a band's declared action key.
  ///
  /// The keys come from the protocol, so an unknown key falls through as itself
  /// rather than being guessed at — a wrong "reassurance" sentence would be a
  /// clinical claim this app has no basis for.
  static String _actionLabel(String key) => switch (key) {
        'action.self_care' =>
          'Self-care advice and routine follow-up at the next visit.',
        'action.phc_review' =>
          'Review at the primary health centre, with the measurements in this '
              'report.',
        'action.specialist_review' =>
          'Refer for specialist assessment, carrying this report.',
        'action.clinical_review' =>
          'Clinical review before any further screening conclusion is drawn.',
        _ => key,
      };

  static Map<String, String> _modelVersions(List<BranchScore> branches) {
    final versions = <String, String>{};
    for (final branch in branches) {
      versions[branch.modelId] =
          'v${branch.modelVersion} · ${branch.trainingStatus.honestyLabel}';
    }
    return versions;
  }
}

class _ContributionTile extends StatelessWidget {
  const _ContributionTile({required this.contribution});

  final BranchContribution contribution;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  contribution.branch.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${(contribution.score * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          Text(
            'capture confidence ${(contribution.confidence * 100).round()}% · '
            'weight ${contribution.effectiveWeight.toStringAsFixed(2)} '
            '(declared ${contribution.declaredWeight.toStringAsFixed(2)})',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          Text(
            contribution.trainingStatus.honestyLabel,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          if (contribution.placementNote != null)
            Text(
              contribution.placementNote!,
              style: const TextStyle(fontSize: 12, height: 1.3),
            ),
        ],
      ),
    );
  }
}
