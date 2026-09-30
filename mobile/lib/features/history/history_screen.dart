// History (PRD §19.1, §28 FR-21).
//
// PRD §21.1 makes the Arogya Patient ID the operational identifier, so this
// screen searches on it — and on the patient's name, which is how a worker
// actually finds someone. It deliberately does NOT search the protected identity
// reference: a searchable identity field is a lookup key again, which is what
// §7.2 and DECISIONS.md D7 set out to avoid.
//
// Records kept on this device only (no consent for sync) are marked as such, so
// a worker can see at a glance which records will never leave the phone.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../data/records.dart';
import '../widgets/common.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final TextEditingController _query = TextEditingController();
  Future<_HistoryData>? _data;

  @override
  void initState() {
    super.initState();
    _data = _load('');
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<_HistoryData> _load(String query) async {
    final repos = await ref.read(repositoriesProvider.future);
    final patients = await repos.patients.search(query, limit: 100);
    return _HistoryData(
      patients: patients,
      screenings: await repos.screenings.recent(limit: 25),
      localOnly:
          patients.where((p) => p.syncState == SyncState.localOnly).length,
    );
  }

  void _search(String value) => setState(() => _data = _load(value));

  @override
  Widget build(BuildContext context) {
    final s = context.strings;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('history.title'))),
      body: FutureBuilder<_HistoryData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorView(
              error: snapshot.error!,
              onRetry: () => _search(_query.text),
            );
          }
          if (!snapshot.hasData) return const LoadingView();
          final data = snapshot.data!;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _query,
                onChanged: _search,
                decoration: InputDecoration(
                  labelText: s.t('history.search'),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _query.clear();
                            _search('');
                          },
                        ),
                ),
              ),
              const SizedBox(height: 16),

              SectionCard(
                title: 'Patients',
                subtitle: '${data.patients.length} record'
                    '${data.patients.length == 1 ? '' : 's'} matched'
                    '${data.localOnly == 0 ? '' : ' · ${data.localOnly} kept on '
                        'this device only (no consent to sync)'}',
                child: data.patients.isEmpty
                    ? Text(s.t('history.empty'))
                    : Column(
                        children: [
                          for (final patient in data.patients)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.person_outline),
                              title: Text(patient.name),
                              subtitle: Text(
                                '${patient.arogyaPatientId} · '
                                '${_short(patient.createdAt)}'
                                '${patient.consentGiven ? '' : ' · no consent recorded'}',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => context.push(
                                '/patient/${patient.arogyaPatientId}',
                              ),
                            ),
                        ],
                      ),
              ),

              SectionCard(
                title: 'Recent screenings',
                subtitle: 'Newest first, across every patient on this device.',
                child: data.screenings.isEmpty
                    ? Text(s.t('history.empty'))
                    : Column(
                        children: [
                          for (final screening in data.screenings)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              leading: const Icon(Icons.assignment_outlined),
                              title: Text(screening.arogyaPatientId),
                              subtitle: Text(
                                '${_statusLabel(screening.status)} · '
                                '${_short(screening.startedAt)}',
                              ),
                              onTap: () => context.push(
                                '/patient/${screening.arogyaPatientId}',
                              ),
                            ),
                        ],
                      ),
              ),

              const SizedBox(height: 20),
            ],
          );
        },
      ),
    );
  }

  static String _statusLabel(ScreeningStatus status) => switch (status) {
        ScreeningStatus.draft => 'Draft',
        ScreeningStatus.questionnaireComplete => 'Questionnaire done',
        ScreeningStatus.stage1Complete => 'Stage 1 done',
        ScreeningStatus.jointComplete => 'Joint assessed',
        ScreeningStatus.completed => 'Completed',
        ScreeningStatus.abandoned => 'Abandoned',
      };

  static String _short(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _HistoryData {
  const _HistoryData({
    required this.patients,
    required this.screenings,
    required this.localOnly,
  });

  final List<Patient> patients;
  final List<Screening> screenings;
  final int localOnly;
}
