// Patient detail (PRD §19.1, §21.1, §7.2).
//
// This is where a longitudinal record is read. Two presentation decisions come
// straight from the PRD:
//
//   * The protected identity reference is shown MASKED, using the same helper
//     the registration screen uses, and it is never the lookup key — the Arogya
//     Patient ID above it is (PRD §7.2, §25.1, DECISIONS.md D7).
//   * A record created without consent is marked local-only, because it will
//     never be uploaded and a worker reading this screen should know that before
//     they tell a patient their record has been shared (FR-05, §25.2).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../core/ids.dart';
import '../../data/records.dart';
import '../widgets/common.dart';

class PatientDetailScreen extends ConsumerStatefulWidget {
  const PatientDetailScreen({super.key, required this.arogyaPatientId});

  final String arogyaPatientId;

  @override
  ConsumerState<PatientDetailScreen> createState() => _PatientDetailScreenState();
}

class _PatientDetailScreenState extends ConsumerState<PatientDetailScreen> {
  Future<_PatientData?>? _data;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_PatientData?> _load() async {
    final repos = await ref.read(repositoriesProvider.future);
    final patient = await repos.patients.byId(widget.arogyaPatientId);
    if (patient == null) return null;
    return _PatientData(
      patient: patient,
      screenings: await repos.screenings.forPatient(widget.arogyaPatientId),
    );
  }

  void _reload() => setState(() => _data = _load());

  /// Starts a fresh screening for this patient.
  ///
  /// A new screening is created rather than the previous one being reopened: a
  /// screening is a dated clinical encounter, and appending a second assessment
  /// to the first would make the record ambiguous about which measurement
  /// belongs to which visit.
  Future<void> _startScreening(Patient patient) async {
    final worker = ref.read(authProvider);
    if (worker == null) {
      setState(() => _error = 'No worker is signed in on this device.');
      return;
    }

    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      final repos = await ref.read(repositoriesProvider.future);
      final registry = await ref.read(registryProvider.future);

      final screening = await repos.screenings.create(
        arogyaPatientId: patient.arogyaPatientId,
        workerId: worker.workerId,
        registryVersion: registry.registryVersion,
        clinicalStringsVersion: ClinicalStrings.version,
        appVersion: '1.0.0+1',
      );

      ref.read(screeningSessionProvider.notifier).startWith(patient, screening);
      if (mounted) context.go('/questionnaire');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;

    return Scaffold(
      appBar: AppBar(title: Text(widget.arogyaPatientId)),
      body: FutureBuilder<_PatientData?>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorView(error: snapshot.error!, onRetry: _reload);
          }
          if (!snapshot.hasData && snapshot.connectionState != ConnectionState.done) {
            return const LoadingView();
          }

          final data = snapshot.data;
          if (data == null) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MessageCard(
                    severity: MessageSeverity.error,
                    message: 'No patient on this device has that Arogya Patient '
                        'ID. It may have been mistyped, or the record may live on '
                        'another device.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => context.go('/home'),
                    child: Text(s.t('home.title')),
                  ),
                ],
              ),
            );
          }

          final patient = data.patient;
          final session = ref.watch(screeningSessionProvider);
          final canResume = session.patient?.arogyaPatientId ==
              patient.arogyaPatientId;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                title: patient.name,
                subtitle: patient.arogyaPatientId,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      patient.arogyaPatientId,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _fact('Age', patient.ageYears?.toString() ?? 'not recorded'),
                    _fact('Sex', patient.sex.wire),
                    _fact('District', patient.district ?? 'not recorded'),
                    MeasurementTile(
                      label: s.t('patient.bmi'),
                      value: computeBmi(
                        heightCm: patient.heightCm,
                        weightKg: patient.weightKg,
                      ),
                      unit: 'kg/m²',
                      caveat: patient.heightCm == null || patient.weightKg == null
                          ? 'Needs both height and weight.'
                          : null,
                    ),
                    _fact(
                      'Protected identity reference',
                      patient.protectedIdentity == null
                          ? 'not recorded'
                          : ArogyaPatientId.maskIdentity(patient.protectedIdentity!),
                    ),
                    _fact(
                      'Consent to store and sync screening data',
                      patient.consentGiven
                          ? 'recorded ${_short(patient.consentAt)}'
                          : 'NOT recorded — this record stays on this device',
                    ),
                    _fact('Recorded', _short(patient.createdAt)),
                  ],
                ),
              ),

              if (!patient.consentGiven)
                const MessageCard(
                  severity: MessageSeverity.warning,
                  title: 'No consent recorded',
                  message: 'This record is marked local-only. It is not queued '
                      'for upload, and no screening stored against it will leave '
                      'this device (PRD §25.2, FR-05).',
                ),

              SectionCard(
                title: 'Screenings',
                subtitle: data.screenings.isEmpty
                    ? 'No screening has been recorded for this patient yet.'
                    : '${data.screenings.length} on this device',
                child: Column(
                  children: [
                    for (final screening in data.screenings)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.assignment_outlined),
                        title: Text(_statusLabel(screening.status)),
                        subtitle: Text(
                          '${_short(screening.startedAt)} · '
                          '${screening.screeningId}'
                          '${screening.syncState == SyncState.pending ? ' · waiting to sync' : ''}',
                        ),
                      ),
                  ],
                ),
              ),

              if (_error != null)
                MessageCard(message: _error!, severity: MessageSeverity.error),

              const SizedBox(height: 8),
              if (canResume)
                FilledButton.icon(
                  onPressed: () => _resume(session),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('RESUME SCREENING'),
                )
              else
                FilledButton.icon(
                  onPressed: _starting ? null : () => _startScreening(patient),
                  icon: const Icon(Icons.add),
                  label: Text(_starting ? 'Starting…' : 'START NEW SCREENING'),
                ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => context.push('/history'),
                child: Text(s.t('history.title')),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  void _resume(ScreeningSessionState session) {
    if (!session.hasAnswers) {
      context.go('/questionnaire');
    } else if (!session.hasStage1) {
      context.go('/screen');
    } else if (!session.hasJoint) {
      context.go('/risk-map');
    } else {
      context.go('/result');
    }
  }

  static Widget _fact(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: const TextStyle(fontSize: 13.5)),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  static String _statusLabel(ScreeningStatus status) => switch (status) {
        ScreeningStatus.draft => 'Draft',
        ScreeningStatus.questionnaireComplete => 'Questionnaire complete',
        ScreeningStatus.stage1Complete => 'Whole-body screen complete',
        ScreeningStatus.jointComplete => 'Joint assessment complete',
        ScreeningStatus.completed => 'Completed',
        ScreeningStatus.abandoned => 'Abandoned',
      };

  static String _short(String? iso) {
    if (iso == null) return 'not recorded';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _PatientData {
  const _PatientData({required this.patient, required this.screenings});

  final Patient patient;
  final List<Screening> screenings;
}
