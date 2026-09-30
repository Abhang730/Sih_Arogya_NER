// Report generation (PRD §24.1, §32.5 step 9, §28 FR-25).
//
// The report exists because the product's output leaves the phone: a paper copy
// goes to the patient, and a copy travels with a referral. So three things are
// non-negotiable here:
//
//   * The screening-not-diagnosis disclaimer is printed on the report itself,
//     not just shown on screen (FR-25).
//   * Everything the result screen disclosed is printed too: the caveats, the
//     branches that could not contribute, the uncalibrated-weights note and the
//     sensor-placement disclosure. A report that hides those would be the one
//     artefact a specialist reads without the caveats.
//   * The report is rendered in English. The bundled PDF font set covers Latin
//     text only; printing Devanagari or Bengali with it would produce blank
//     boxes, so the language of the printed artefact is stated rather than
//     silently mangled. Localised report fonts are a packaging task, not a
//     formatting preference.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../core/ids.dart';
import '../../domain/protocol/registry.dart';
import '../../platform/files/file_saver.dart';
import '../../screening/assessment_engine.dart';
import '../widgets/common.dart';

/// Version of the report layout itself, stored with every generated report.
const String reportVersion = '1.0.0';

class ReportScreen extends ConsumerStatefulWidget {
  const ReportScreen({super.key});

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> {
  Uint8List? _bytes;
  String? _storedPath;
  bool _busy = false;
  String? _error;
  String? _status;

  Future<void> _generate() async {
    final session = ref.read(screeningSessionProvider);
    final outcome = session.jointOutcome;

    if (outcome == null) {
      setState(() => _error = 'There is no assessment in this session to report.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });

    try {
      final registry = await ref.read(registryProvider.future);
      final repos = await ref.read(repositoriesProvider.future);
      final worker = ref.read(authProvider);
      final screening = session.screening;

      final document = await _buildDocument(
        session: session,
        outcome: outcome,
        registry: registry,
        worker: worker?.displayName,
        phc: worker?.phc,
        district: worker?.district ?? session.patient?.district,
      );
      final bytes = await document.save();

      final fileName = 'arogya-ner-${screening?.screeningId ?? 'report'}.pdf';
      final path = await saveBytesToDocuments(bytes: bytes, fileName: fileName);

      if (screening != null) {
        await repos.screenings.saveReport(
          screeningId: screening.screeningId,
          pdfPath: path,
          reportVersion: reportVersion,
          payload: _payload(session, outcome, registry),
        );
        await repos.audit.record(
          action: 'report.generated',
          actor: worker?.workerId,
          recordId: screening.screeningId,
          entity: 'report',
          deviceMeta: {
            'report_version': reportVersion,
            'stored': path != null,
            'bytes': bytes.length,
          },
        );
      }

      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _storedPath = path;
        _busy = false;
        _status = path == null
            ? 'Report generated (${(bytes.length / 1024).toStringAsFixed(0)} kB). '
                'This platform has nowhere to store a file, so use Print or '
                'Share to keep a copy.'
            : 'Report generated and stored on this device.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final session = ref.watch(screeningSessionProvider);

    return Scaffold(
      appBar: AppBar(title: Text(s.t('report.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SafetyBanner(),

          SectionCard(
            title: 'What this report contains',
            subtitle: session.patient == null
                ? null
                : '${session.patient!.name} · '
                    '${session.patient!.arogyaPatientId}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _Bullet('Patient identification (Arogya Patient ID, masked '
                    'identity reference)'),
                _Bullet('Screening context: worker, site, protocol and clinical '
                    'string versions'),
                _Bullet('Whole-body screen: joint markers and reported pain'),
                _Bullet('Targeted joint assessment: questionnaire, camera and '
                    'sensor measurements'),
                _Bullet('Screening indication, contributors, and every branch '
                    'that could not contribute'),
                _Bullet('All caveats, model versions and the disclaimer'),
              ],
            ),
          ),

          SectionCard(
            title: s.t('report.generate'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _generate,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(_busy ? 'Generating…' : 'Generate PDF'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _bytes == null
                            ? null
                            : () => Printing.layoutPdf(
                                  name: 'Arogya-NER report',
                                  onLayout: (_) async => _bytes!,
                                ),
                        icon: const Icon(Icons.print_outlined),
                        label: Text(s.t('report.print')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _bytes == null
                            ? null
                            : () => Printing.sharePdf(
                                  bytes: _bytes!,
                                  filename: 'arogya-ner-report.pdf',
                                ),
                        icon: const Icon(Icons.ios_share),
                        label: Text(s.t('report.share')),
                      ),
                    ),
                  ],
                ),
                if (_status != null) ...[
                  const SizedBox(height: 12),
                  MessageCard(
                    message: _status!,
                    severity: MessageSeverity.success,
                  ),
                ],
                if (_storedPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SelectableText(
                      _storedPath!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),

          if (_error != null)
            MessageCard(message: _error!, severity: MessageSeverity.error),

          SectionCard(
            title: 'Language of the printed report',
            child: Text(
              'Reports are printed in English. The bundled PDF fonts cover Latin '
              'text only, and substituting a font that cannot render a script '
              'would print empty boxes rather than words. The app interface is '
              'localised separately (PRD §20).',
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          const SizedBox(height: 24),
          const SafetyFooter(),
        ],
      ),
    );
  }

  // ── document construction ────────────────────────────────────────────────

  Future<pw.Document> _buildDocument({
    required ScreeningSessionState session,
    required JointAssessmentOutcome outcome,
    required ProtocolRegistry registry,
    String? worker,
    String? phc,
    String? district,
  }) async {
    final fusion = outcome.fusion;
    final versions = {
      for (final branch in fusion.allBranches) branch.modelId: branch.modelVersion,
    };
    // Read into locals: a nullable field cannot be promoted through a getter,
    // and the report must distinguish "not recorded" from a blank.
    final patient = session.patient;
    final screening = session.screening;
    final answers = session.answers;
    final questionnaire = session.questionnaireScore;
    final stage1 = outcome.stage1Map ?? session.stage1RiskMap;
    final generatedAt = DateTime.now();

    final document = pw.Document(
      title: 'Arogya-NER screening report',
      author: 'Arogya-NER',
      subject: 'Musculoskeletal screening report (not a diagnosis)',
    );

    final content = <pw.Widget>[
      pw.Header(
        level: 0,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Arogya-NER',
                style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
            pw.Text('Smart Clinic in a Pocket — musculoskeletal screening record',
                style: const pw.TextStyle(fontSize: 10)),
            pw.SizedBox(height: 6),
            pw.Text('Report version $reportVersion · generated '
                '${_timestamp(generatedAt)}',
                style: const pw.TextStyle(fontSize: 9)),
          ],
        ),
      ),

      _section('Patient', [
        _pair('Arogya Patient ID', patient?.arogyaPatientId),
        _pair('Name', patient?.name),
        _pair('Age', patient?.ageYears?.toString()),
        _pair('Sex', patient?.sex.wire),
        _pair('District', patient?.district),
        _pair(
          'Protected identity reference',
          patient?.protectedIdentity == null
              ? 'not recorded'
              : ArogyaPatientId.maskIdentity(patient!.protectedIdentity!),
        ),
        _pair(
          'BMI',
          computeBmi(
            heightCm: patient?.heightCm,
            weightKg: patient?.weightKg,
          )
              ?.toStringAsFixed(1),
        ),
        _pair('Consent recorded', patient?.consentGiven == true ? 'yes' : 'no'),
      ]),

      _section('Screening context', [
        _pair('Screening ID', screening?.screeningId),
        _pair('Status', screening?.status.wire),
        _pair('Started', screening?.startedAt),
        _pair('Worker', worker),
        _pair('PHC', phc),
        _pair('Trained at / site', district),
        _pair('Protocol registry', registry.registryVersion),
        _pair('Clinical string version', screening?.clinicalStringsVersion),
        _pair('App version', screening?.appVersion),
        _pair(
          'Pose engine',
          session.stage1PoseEngineId,
          note: session.stage1Synthetic
              ? 'SIMULATED landmarks — not measurements of this patient'
              : null,
        ),
      ]),

      if (stage1 != null)
        _section('Whole-body screen (where to look next)', [
          ...(stage1.markers.take(12).map((m) => _pair(
                '${m.jointId} · ${m.side}',
                m.isScored
                    ? '${(m.score! * 100).toStringAsFixed(0)}% '
                        '(confidence ${(m.confidence * 100).round()}%)'
                    : 'not assessed — no validated model',
              ))),
          _pair('Markers scored', '${stage1.markers.where((m) => m.isScored).length}'
              ' of ${stage1.markers.length}'),
          if (answers != null)
            _pair(
              'Patient-reported pain regions',
              answers.painRegions.isEmpty
                  ? 'none reported'
                  : answers.painRegions.keys.join(', '),
            ),
        ]),

      _section('Targeted joint assessment', [
        _pair('Joint', outcome.jointId),
        _pair('Side', outcome.side),
        _pair('Protocol version', outcome.protocolVersion),
        _pair(
          'Camera capture confidence',
          '${(outcome.cameraConfidence * 100).round()}%',
        ),
        _pair(
          'Motion Pod placements recorded',
          outcome.sensorPlacement ?? 'no pod trial recorded',
          note: outcome.sensorPlacement == null
              ? null
              : 'The trained model was fitted at a different placement '
                  '(lumbar L5 + dorsal foot), so the sensor component is not '
                  'identical to the training rig.',
        ),
        _pair(
          'Movement tests captured',
          '${outcome.testResults.length}',
        ),
      ]),

      if (questionnaire != null)
        _section('Joint questionnaire', [
          _pair('Instrument', '${questionnaire.instrument} '
              '${questionnaire.instrumentVersion}'),
          _pair(
            'Total',
            '${questionnaire.totalRaw.toStringAsFixed(0)} of '
                '${questionnaire.totalMax.toStringAsFixed(0)}'
                '${questionnaire.isComplete ? '' : ' (incomplete)'}',
          ),
          ...questionnaire.subscales.values.map((sub) => _pair(
                sub.name,
                '${sub.raw.toStringAsFixed(0)} of ${sub.max.toStringAsFixed(0)} '
                    '(${sub.answered}/${sub.itemCount} answered)',
              )),
          _pair('Declared severity bands', questionnaire.band == null
              ? 'none — a total is reported, not a category'
              : questionnaire.band!.labelKey),
        ]),

      _section('Screening indication', [
        _pair(
          'Combined screening index',
          fusion.hasScore
              ? '${(fusion.score! * 100).toStringAsFixed(0)}%'
              : 'not produced — no branch could score this assessment',
          note: fusion.isCalibrated
              ? null
              : 'Uncalibrated: fusion weights are declared engineering '
                  'defaults, not fitted coefficients. The index orders triage '
                  'priority; it is not a probability of disease.',
        ),
        _pair('Indication band', fusion.band?.labelKey ?? 'not assessed'),
        _pair('Band thresholds', registry
            .protocolFor(outcome.jointId)
            .riskLogic
            .thresholdProvenance),
        _pair('Branch agreement', fusion.contributions.length < 2
            ? 'single contributing branch'
            : '${(fusion.agreement * 100).round()}%'),
        _pair('Recommended action', fusion.referralActionKey),
      ]),

      _section('Evidence that contributed', [
        for (final contribution in fusion.contributions)
          _pair(
            contribution.branch.displayName,
            '${(contribution.score * 100).toStringAsFixed(0)}% · confidence '
                '${(contribution.confidence * 100).round()}% · weight '
                '${contribution.effectiveWeight.toStringAsFixed(2)}',
            note: '${contribution.modelId} '
                'v${versions[contribution.modelId] ?? 'version not recorded'} — '
                '${contribution.trainingStatus.honestyLabel}',
          ),
        if (fusion.contributions.isEmpty)
          _pair('Contributors', 'none'),
      ]),

      _section('Evidence that could not contribute', [
        for (final branch in fusion.allBranches.where((b) => !b.isAvailable))
          _pair(
            branch.branch.displayName,
            branch.reason?.explanation ?? 'unavailable',
            note: '${branch.modelId} v${branch.modelVersion} — '
                '${branch.trainingStatus.honestyLabel}',
          ),
        if (fusion.allBranches.every((b) => b.isAvailable))
          _pair('Unavailable branches', 'none'),
      ]),

      _section('Caveats', [
        if (outcome.caveats.isEmpty) _pair('Caveats', 'none recorded'),
        ...outcome.caveats.map((c) => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.Text('• $c', style: const pw.TextStyle(fontSize: 9)),
            )),
      ]),

      _section('Model versions', [
        for (final branch in fusion.allBranches)
          _pair(branch.modelId, 'v${branch.modelVersion} — '
              '${branch.trainingStatus.honestyLabel}'),
        _pair('Fusion configuration', fusion.configProvenance),
      ]),

      pw.SizedBox(height: 12),
      pw.Container(
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey700),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Screening support only. This is not a diagnosis.',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
            pw.SizedBox(height: 4),
            pw.Text(_englishDisclaimer(), style: const pw.TextStyle(fontSize: 9)),
          ],
        ),
      ),
    ];

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Arogya-NER · page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ),
        build: (context) => content,
      ),
    );

    return document;
  }

  /// The disclaimer in the language the PDF can actually render.
  static String _englishDisclaimer() {
    final text = ClinicalStrings.lookup('disclaimer', 'en', 'text');
    return text ??
        'Arogya-NER indicates likelihood and recommends next steps. It does '
            'not diagnose osteoarthritis or any other condition. A qualified '
            'clinician must interpret these results.';
  }

  static pw.Widget _section(String title, List<pw.Widget> rows) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(height: 10),
          pw.Text(title.toUpperCase(),
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.teal900,
              )),
          pw.Divider(thickness: 0.5, color: PdfColors.grey500),
          ...rows,
        ],
      );

  /// A label/value row. A null or empty value prints "not measured" rather than
  /// a blank or a zero, matching the rule the screens follow (PRD §26.5).
  static pw.Widget _pair(String label, String? value, {String? note}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 150,
                  child: pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
                ),
                pw.Expanded(
                  child: pw.Text(
                    (value == null || value.trim().isEmpty)
                        ? 'not measured'
                        : value,
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (note != null)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 150, top: 1),
                child: pw.Text(note,
                    style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey800)),
              ),
          ],
        ),
      );

  /// The machine-readable record of what was printed.
  Map<String, Object?> _payload(
    ScreeningSessionState session,
    JointAssessmentOutcome outcome,
    ProtocolRegistry registry,
  ) {
    final screening = session.screening;
    final fusion = outcome.fusion;

    return {
      'report_version': reportVersion,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'screening_id': screening?.screeningId,
      'arogya_patient_id': session.patient?.arogyaPatientId,
      'worker_id': ref.read(authProvider)?.workerId,
      'joint': outcome.jointId,
      'side': outcome.side,
      'protocol_version': outcome.protocolVersion,
      'registry_version': registry.registryVersion,
      'clinical_strings_version': screening?.clinicalStringsVersion,
      'fused_score': fusion.score,
      'risk_band': fusion.band?.id,
      'referral_action': fusion.referralActionKey,
      'calibrated': fusion.isCalibrated,
      'agreement': fusion.agreement,
      'questionnaire': session.questionnaireScore?.toJson(),
      'contributors': fusion.contributions
          .map((c) => {
                'branch': c.branch.wire,
                'model_id': c.modelId,
                'score': c.score,
                'confidence': c.confidence,
                'effective_weight': c.effectiveWeight,
                'training_status': c.trainingStatus.wire,
              })
          .toList(growable: false),
      'unavailable_branches': fusion.allBranches
          .where((b) => !b.isAvailable)
          .map((b) => {
                'branch': b.branch.wire,
                'reason': b.reason?.wire,
                'model_id': b.modelId,
              })
          .toList(growable: false),
      'caveats': outcome.caveats,
      'synthetic': session.usedSimulatedData,
      'disclaimer_key': 'disclaimer.screening_not_diagnosis',
    };
  }

  static String _timestamp(DateTime when) {
    final local = when.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('•  '),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.35))),
          ],
        ),
      );
}
