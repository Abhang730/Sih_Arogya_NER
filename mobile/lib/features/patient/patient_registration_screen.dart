// Patient registration (PRD §7.2, §28 FR-03/FR-04/FR-05, §32.5 step 2).
//
// The design point this screen exists to demonstrate: the Arogya Patient ID is
// generated here, on the device, and the protected identity field is optional,
// encrypted, masked in display and never a lookup key (DECISIONS.md D7). No
// Aadhaar-specific validation, storage or processing is implemented, because the
// workflow does not need it.
//
// Consent is captured BEFORE any screening data can be stored (FR-05), and a
// record created without consent is marked local-only so it is never uploaded
// (PRD §25.2).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/strings.dart';
import '../../core/ids.dart';
import '../../data/records.dart';
import '../widgets/common.dart';

class PatientRegistrationScreen extends ConsumerStatefulWidget {
  const PatientRegistrationScreen({super.key});

  @override
  ConsumerState<PatientRegistrationScreen> createState() =>
      _PatientRegistrationScreenState();
}

class _PatientRegistrationScreenState
    extends ConsumerState<PatientRegistrationScreen> {
  final _name = TextEditingController();
  final _age = TextEditingController();
  final _height = TextEditingController();
  final _weight = TextEditingController();
  final _district = TextEditingController();
  final _identity = TextEditingController();

  PatientSex _sex = PatientSex.unspecified;
  bool _consent = false;
  bool _saving = false;
  String? _error;

  /// Previewed to the worker before saving, so the ID they write on paper is the
  /// ID that ends up in the record.
  late String _previewId = ArogyaPatientId.generate();

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _height.dispose();
    _weight.dispose();
    _district.dispose();
    _identity.dispose();
    super.dispose();
  }

  double? get _bmi => computeBmi(
        heightCm: double.tryParse(_height.text.trim()),
        weightKg: double.tryParse(_weight.text.trim()),
      );

  Future<void> _save() async {
    final s = context.strings;
    final worker = ref.read(authProvider);

    if (_name.text.trim().isEmpty) {
      setState(() => _error = s.t('patient.error.name'));
      return;
    }

    final age = int.tryParse(_age.text.trim());
    if (age == null || age < 1 || age > 120) {
      setState(() => _error = s.t('patient.error.age'));
      return;
    }

    if (!_consent) {
      // Not an error the worker can ignore: FR-05 requires consent before
      // identifiable screening data is stored.
      setState(() => _error = s.t('patient.error.consent'));
      return;
    }

    if (worker == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final repos = await ref.read(repositoriesProvider.future);
      final patient = await repos.patients.create(
        name: _name.text,
        createdBy: worker.workerId,
        ageYears: age,
        sex: _sex,
        heightCm: double.tryParse(_height.text.trim()),
        weightKg: double.tryParse(_weight.text.trim()),
        district: _district.text.trim().isEmpty ? null : _district.text.trim(),
        protectedIdentity: _identity.text.trim().isEmpty ? null : _identity.text,
        consentGiven: _consent,
      );

      final registry = await ref.read(registryProvider.future);
      final screening = await repos.screenings.create(
        arogyaPatientId: patient.arogyaPatientId,
        workerId: worker.workerId,
        registryVersion: registry.registryVersion,
        // The clinical string version is stamped onto every screening record so
        // a score is traceable to the exact instrument wording that produced it
        // (PRD §20.2).
        clinicalStringsVersion: ClinicalStrings.version,
        appVersion: '1.0.0+1',
      );

      ref.read(screeningSessionProvider.notifier).startWith(patient, screening);

      if (mounted) context.go('/questionnaire');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('patient.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: s.t('patient.arogya_id'),
            subtitle: s.t('patient.arogya_id_help'),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _previewId,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'New ID',
                  icon: const Icon(Icons.refresh),
                  onPressed: () =>
                      setState(() => _previewId = ArogyaPatientId.generate()),
                ),
              ],
            ),
          ),

          SectionCard(
            title: 'Patient details',
            child: Column(
              children: [
                TextField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: s.t('patient.name'),
                    border: const OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _age,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: s.t('patient.age'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<PatientSex>(
                        initialValue: _sex,
                        decoration: InputDecoration(
                          labelText: s.t('patient.sex'),
                          border: const OutlineInputBorder(),
                        ),
                        // Every value the state can hold needs an item. The
                        // default is `unspecified`, so omitting it made
                        // DropdownButton throw on the first build of this screen
                        // — the registration step was unreachable in a debug
                        // build, and in release it would have rendered without a
                        // selection.
                        items: [
                          DropdownMenuItem(
                            value: PatientSex.unspecified,
                            child: Text(s.t('patient.sex.unspecified')),
                          ),
                          DropdownMenuItem(
                            value: PatientSex.female,
                            child: Text(s.t('patient.sex.female')),
                          ),
                          DropdownMenuItem(
                            value: PatientSex.male,
                            child: Text(s.t('patient.sex.male')),
                          ),
                          DropdownMenuItem(
                            value: PatientSex.other,
                            child: Text(s.t('patient.sex.other')),
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _sex = v ?? PatientSex.unspecified),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _height,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: s.t('patient.height'),
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _weight,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: s.t('patient.weight'),
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // A null BMI renders as "not measured", never as 0.
                MeasurementTile(
                  label: s.t('patient.bmi'),
                  value: _bmi,
                  unit: 'kg/m²',
                  caveat: _bmi == null
                      ? 'Needs both height and weight.'
                      : null,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _district,
                  decoration: InputDecoration(
                    labelText: s.t('patient.district'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),

          SectionCard(
            title: s.t('patient.identity'),
            subtitle: s.t('patient.identity_help'),
            child: TextField(
              controller: _identity,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Optional',
              ),
            ),
          ),

          SectionCard(
            title: s.t('patient.consent'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.t('patient.consent_detail'),
                  style: const TextStyle(fontSize: 13.5, height: 1.35),
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  value: _consent,
                  onChanged: (v) => setState(() => _consent = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Consent recorded'),
                ),
              ],
            ),
          ),

          if (_error != null)
            MessageCard(message: _error!, severity: MessageSeverity.error),

          const SizedBox(height: 8),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(s.t('action.next')),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
