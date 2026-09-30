// Settings (PRD §19.1, §20, §21.2, §22.3).
//
// Three facts are surfaced here that a product is usually tempted to bury, and
// the PRD makes each of them binding:
//
//   * §20.1 language coverage. Nine NER languages are listed; three have any
//     strings at all, and only one of those is "core". A language with no
//     translation table says so instead of quietly falling back to English.
//   * §21.2 encryption posture. The store reports how it was actually opened.
//     On a platform with no SQLCipher the screen says the device is not
//     field-deployable, in those words.
//   * §22.3 offline-first sync. Records are queued locally and upload when a
//     connection and a configured endpoint exist. This build has no backend
//     endpoint configured, and the screen says that rather than showing a
//     spinner that never resolves.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../widgets/common.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int? _pending;

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  Future<void> _loadPending() async {
    try {
      final repos = await ref.read(repositoriesProvider.future);
      final pending = await repos.sync.pendingCount();
      if (mounted) setState(() => _pending = pending);
    } catch (_) {
      // A queue that cannot be read is reported as unknown, not as zero: zero
      // reads as "everything is synced", which is a different claim.
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final language = ref.watch(languageProvider);
    final worker = ref.watch(authProvider);
    final security = ref.watch(databaseSecurityProvider);
    final database = ref.watch(databaseProvider).value;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('settings.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: s.t('settings.worker_profile'),
            subtitle: worker == null
                ? 'No worker is signed in.'
                : '${worker.displayName} · ${worker.role}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (worker != null) ...[
                  _FactRow(label: 'Worker ID', value: worker.workerId),
                  _FactRow(
                    label: 'PHC / district',
                    value: '${worker.phc ?? 'not recorded'} · '
                        '${worker.district ?? 'not recorded'}',
                  ),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    ref.read(authProvider.notifier).signOut();
                    ref.read(screeningSessionProvider.notifier).reset();
                    context.go('/login');
                  },
                  icon: const Icon(Icons.logout),
                  label: Text(s.t('settings.sign_out')),
                ),
              ],
            ),
          ),

          SectionCard(
            title: s.t('settings.language'),
            subtitle: 'Interface language. The clinical report is printed in '
                'English (see the Report screen).',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<AppLanguage>(
                  initialValue: language,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                  items: [
                    for (final option in AppLanguage.values)
                      DropdownMenuItem(
                        value: option,
                        child: Text(
                          '${option.label} · ${option.coverage.replaceAll('_', ' ')}',
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      ref.read(languageProvider.notifier).select(value);
                    }
                  },
                ),
                const SizedBox(height: 10),
                if (language.isPlanned)
                  MessageCard(
                    message: s.tArgs('settings.language_planned', {
                      'language': language.label,
                    }),
                    severity: MessageSeverity.warning,
                  )
                else if (!language.hasTranslations)
                  MessageCard(
                    message: '${language.label} is listed for this region but no '
                        'strings are bundled yet, so labels fall back to English.',
                    severity: MessageSeverity.info,
                  )
                else
                  MessageCard(
                    message: '${language.label} is a '
                        '${language.coverage.replaceAll('_', ' ')} language in '
                        'this release. Un-translated labels fall back to '
                        'English and are recorded for a release check.',
                    severity: MessageSeverity.success,
                  ),
                const SizedBox(height: 4),
                Text(
                  'Nine North Eastern Region languages are listed so the '
                  'roadmap is visible; three have strings today. Coverage is '
                  'reported, not implied (PRD §20.1).',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          SectionCard(
            title: s.t('settings.device'),
            trailing: Icon(
              security.isEncrypted ? Icons.lock_outline : Icons.lock_open_outlined,
              color: security.isEncrypted
                  ? const Color(0xFF1B5E20)
                  : const Color(0xFFB71C1C),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MessageCard(
                  message: security.description,
                  severity: security.isEncrypted
                      ? MessageSeverity.success
                      : MessageSeverity.error,
                  title: security.isEncrypted
                      ? 'Encrypted at rest'
                      : 'NOT encrypted at rest',
                ),
                if (database != null)
                  Text(
                    'Store: ${database.path}',
                    style: const TextStyle(fontSize: 12),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Clinical string version: ${ClinicalStrings.version}',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ],
            ),
          ),

          SectionCard(
            title: s.t('settings.sync'),
            subtitle: _pending == null
                ? 'Queue state unknown'
                : (_pending! == 0
                    ? s.t('sync.none')
                    : s.tArgs('sync.pending', {'count': '$_pending'})),
            trailing: Icon(
              (_pending ?? 0) > 0
                  ? Icons.cloud_upload_outlined
                  : Icons.cloud_done_outlined,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Every record is written locally first and queued for upload. '
                  'A screening is never blocked waiting for a connection '
                  '(PRD §18.1, §22.3).',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                const MessageCard(
                  message: 'No cloud endpoint is configured in this build, so '
                      'the queue is not being uploaded yet. Records stay on this '
                      'device and remain queued, in order, until one is.',
                  severity: MessageSeverity.warning,
                ),
              ],
            ),
          ),

          SectionCard(
            title: 'About this build',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _FactRow(
                  label: 'Product',
                  value: 'Arogya-NER · screening support, not diagnosis',
                ),
                _FactRow(
                  label: 'Trained models',
                  value: 'Knee and hip wearable-sensor branches. Camera, '
                      'whole-body localisation, clinical-tabular and imaging '
                      'branches are untrained and say so on screen.',
                ),
                _FactRow(
                  label: 'Sensor hardware',
                  value: 'The Arogya Motion Pod firmware is not built yet. The '
                      'app can use a clearly-labelled simulated signal.',
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          const SafetyBanner(dense: true),
        ],
      ),
    );
  }
}

/// A label/value fact, used where the value is not a measurement.
///
/// Deliberately NOT [MeasurementTile]: that widget renders a missing value as
/// "not measured", which is correct for a clinical measurement and wrong for a
/// static fact such as a worker id.
class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          Text(value, style: const TextStyle(fontSize: 14.5, height: 1.35)),
        ],
      ),
    );
  }
}
