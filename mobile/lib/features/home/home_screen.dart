// Home (PRD §19.1, §32.5 step 1).
//
// Shows the three things a field worker needs before starting: whether records
// are waiting to sync, what is still in draft, and what happened recently. It
// deliberately does not show any clinical summary — a home screen is not a
// result surface, and the safety guardrail applies to result boundaries.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../data/records.dart';
import '../widgets/common.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Future<_HomeData>? _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_HomeData> _load() async {
    final repos = await ref.read(repositoriesProvider.future);
    final registry = await ref.read(registryProvider.future);
    return _HomeData(
      drafts: await repos.screenings.drafts(),
      recent: await repos.screenings.recent(limit: 10),
      pendingSync: await repos.sync.pendingCount(),
      patientCount: await repos.patients.count(),
      registryVersion: registry.registryVersion,
    );
  }

  void _reload() => setState(() => _data = _load());

  @override
  Widget build(BuildContext context) {
    final worker = ref.watch(authProvider);
    final session = ref.watch(screeningSessionProvider);
    final s = context.strings;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t('home.title')),
        actions: [
          IconButton(
            tooltip: s.t('home.history'),
            icon: const Icon(Icons.history),
            onPressed: () => context.push('/history'),
          ),
          IconButton(
            tooltip: s.t('home.settings'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: FutureBuilder<_HomeData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorView(error: snapshot.error!, onRetry: _reload);
          }
          if (!snapshot.hasData) {
            return const LoadingView(message: 'Opening the local record store…');
          }
          final data = snapshot.data!;

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (worker != null)
                  Text(
                    '${worker.displayName}'
                    '${worker.phc == null ? '' : ' · ${worker.phc}'}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                const SizedBox(height: 4),
                Text(
                  'Registry ${data.registryVersion} · '
                  '${data.patientCount} patient record'
                  '${data.patientCount == 1 ? '' : 's'} on this device',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),

                _SyncStatusCard(pending: data.pendingSync, onSynced: _reload),

                if (session.hasPatient) ...[
                  const SizedBox(height: 6),
                  SectionCard(
                    title: 'Screening in progress',
                    subtitle:
                        '${session.patient!.name} · ${session.patient!.arogyaPatientId}\n'
                        'Completed: ${session.completedStages.join(' → ')}',
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: () => _resume(session),
                            child: const Text('RESUME'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 6),
                FilledButton.icon(
                  onPressed: () => context.push('/patient/new'),
                  icon: const Icon(Icons.add),
                  label: Text(s.t('home.new_screening')),
                ),

                if (data.drafts.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    s.t('home.drafts'),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  ...data.drafts.map((draft) => _ScreeningTile(
                        screening: draft,
                        onTap: () => context.push(
                          Routes.patientDetailFor(draft.arogyaPatientId),
                        ),
                      )),
                ],

                const SizedBox(height: 20),
                Text(
                  s.t('home.recent'),
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
                if (data.recent.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      s.t('home.no_recent'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ...data.recent.map((screening) => _ScreeningTile(
                        screening: screening,
                        onTap: () => context.push(
                          Routes.patientDetailFor(screening.arogyaPatientId),
                        ),
                      )),
                const SizedBox(height: 24),
                const SafetyBanner(dense: true),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  void _resume(ScreeningSessionState session) {
    if (!session.hasAnswers) {
      context.push('/questionnaire');
    } else if (!session.hasStage1) {
      context.push('/screen');
    } else if (!session.hasJoint) {
      context.push('/risk-map');
    } else {
      context.push('/result');
    }
  }
}

class _HomeData {
  const _HomeData({
    required this.drafts,
    required this.recent,
    required this.pendingSync,
    required this.patientCount,
    required this.registryVersion,
  });

  final List<Screening> drafts;
  final List<Screening> recent;
  final int pendingSync;
  final int patientCount;
  final String registryVersion;
}

class _SyncStatusCard extends ConsumerWidget {
  const _SyncStatusCard({required this.pending, required this.onSynced});

  final int pending;
  final VoidCallback onSynced;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.strings;
    final isPending = pending > 0;

    return SectionCard(
      title: s.t('home.sync_status'),
      subtitle: isPending
          ? s.tArgs('sync.pending', {'count': '$pending'})
          : s.t('sync.none'),
      trailing: Icon(
        isPending ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined,
        color: isPending
            ? const Color(0xFFE65100)
            : const Color(0xFF1B5E20),
      ),
      child: Text(
        'Records are stored on this device first. They upload when a connection '
        'is available and the screening is never blocked waiting for one.',
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ScreeningTile extends StatelessWidget {
  const _ScreeningTile({required this.screening, required this.onTap});

  final Screening screening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusLabel = switch (screening.status) {
      ScreeningStatus.draft => 'Draft',
      ScreeningStatus.questionnaireComplete => 'Questionnaire done',
      ScreeningStatus.stage1Complete => 'Stage 1 done',
      ScreeningStatus.jointComplete => 'Joint assessed',
      ScreeningStatus.completed => 'Completed',
      ScreeningStatus.abandoned => 'Abandoned',
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.assignment_outlined),
      title: Text(screening.arogyaPatientId),
      subtitle: Text(
        '$statusLabel · ${_short(screening.startedAt)}'
        '${screening.syncState == SyncState.pending ? ' · waiting to sync' : ''}',
      ),
      onTap: onTap,
    );
  }

  static String _short(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
