// End-to-end screening flow (PRD §32.5).
//
// This drives the real application widget — the same ArogyaApp the field build
// uses — through the whole MVP path a demonstration would walk:
//
//   provision → patient registration → whole-body questionnaire → three camera
//   tests → body risk map → joint assessment → result → PDF report
//
// Two things make it a real test rather than a smoke test:
//
//   * the database is a real SQLite database created from the shipped schema, so
//     the repositories, the audit trail and the sync queue all actually run;
//   * the screens are driven by their own widgets, so a screen that throws at
//     runtime fails the test. Three genuine defects were found this way while it
//     was being written (a quality check that could never pass, and a capture
//     gate that deadlocked waiting for frames that only a capture could
//     produce), which no amount of reading the code had surfaced.
//
// Where the flow needs a platform capability a test host does not have, the test
// supplies it explicitly instead of letting the app fabricate one:
//   * camera pose detection: [hasRealPoseEngine] is false off Android/iOS, so the
//     synthetic engine runs and the app labels it — the same path the web
//     demonstration build takes;
//   * the documents directory: a fake path provider writes into a temp folder,
//     so the generated PDF is checked on disk rather than assumed.

import 'dart:io';

import 'package:arogya_ner/app/app.dart';
import 'package:arogya_ner/app/providers.dart';
import 'package:arogya_ner/data/db/db_types.dart';
import 'package:arogya_ner/data/db/schema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Serves the documents directory from a temporary folder.
///
/// Extends the platform interface rather than implementing it, which is the
/// supported way to fake path_provider without a device.
class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database database;
  late Directory documents;
  late OpenedDatabase opened;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    // A fresh in-memory database per test, created by the shipped schema
    // statements, so the test cannot pass against a schema the app does not use.
    //
    // The no-isolate factory is required rather than preferred: sqflite_common_ffi
    // normally runs SQLite in its own isolate, and a widget test's fake clock
    // never sees the reply, so every tap that writes would hang. Running SQLite in
    // the test isolate keeps the same SQL and the same schema, which is what the
    // test is asserting about.
    database = await databaseFactoryFfiNoIsolate.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: ArogyaSchema.version,
        onCreate: (db, version) async {
          final batch = db.batch();
          for (final statement in ArogyaSchema.createStatements) {
            batch.execute(statement);
          }
          await batch.commit(noResult: true);
        },
      ),
    );

    documents = await Directory.systemTemp.createTemp('arogya-flow-test');
    PathProviderPlatform.instance = _TempPathProvider(documents.path);

    opened = OpenedDatabase(
      database: database,
      security: DatabaseSecurity.unencryptedDevelopmentFallback,
      path: inMemoryDatabasePath,
    );
  });

  tearDown(() async {
    await database.close();
    if (documents.existsSync()) documents.deleteSync(recursive: true);
  });

  /// A viewport tall enough that a screening screen is fully built, so a step
  /// does not depend on scroll behaviour to be reachable.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) async => opened),
        ],
        child: const ArogyaApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Pumps in small steps.
  ///
  /// pumpAndSettle cannot be used once a capture is running: the synthetic pose
  /// engine emits frames on a periodic timer by design, so "settled" never
  /// arrives and the call would time out on a working app.
  Future<void> pumpFor(WidgetTester tester, Duration duration) async {
    const step = Duration(milliseconds: 100);
    var elapsed = Duration.zero;
    while (elapsed < duration) {
      await tester.pump(step);
      elapsed += step;
    }
  }

  /// Waits for the capture button to become available.
  ///
  /// The quality gate decides availability frame by frame, so a worker (and this
  /// test) waits for the report to pass rather than assuming a fixed delay is
  /// long enough. Failing loudly here is the point: if the gate never passes, no
  /// amount of pumping will start a capture.
  Future<void> waitForCaptureAvailable(WidgetTester tester) async {
    for (var attempt = 0; attempt < 80; attempt++) {
      final button = find.widgetWithText(FilledButton, 'Start capture');
      if (button.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(button).onPressed != null) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    fail('the capture button never became available — the quality gate never '
        'passed for this movement test');
  }

  testWidgets('a worker can screen a patient and produce a report end to end',
      (tester) async {
    await pumpApp(tester);

    // ── step 1: worker provisioning (PRD §32.5 step 1) ────────────────────
    expect(find.text('Worker name'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Worker name'),
      'Asha Devi',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Worker ID'),
      'asha01',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Passcode'),
      'demo1234',
    );
    await tester.tap(find.text('Provision and sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('New screening'), findsOneWidget);

    // ── step 2: patient registration (FR-03, FR-04, FR-05) ────────────────
    await tester.tap(find.text('New screening'));
    await tester.pumpAndSettle();

    // TEMP DEBUG
    // ignore: avoid_print
    print(find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .where((t) => t != null)
        .join(' | '));

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Bina Das');
    await tester.enterText(find.widgetWithText(TextField, 'Age (years)'), '57');
    await tester.enterText(find.widgetWithText(TextField, 'Height (cm)'), '152');
    await tester.enterText(find.widgetWithText(TextField, 'Weight (kg)'), '64');
    await tester.tap(find.text('Consent recorded'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();

    // ── step 3: whole-body questionnaire (FR-06) ──────────────────────────
    expect(find.text('Whole-body questionnaire'), findsOneWidget);

    const itemLabels = [
      'Do you have difficulty rising from a chair?',
      'Do you have difficulty with stairs?',
      'Do you have difficulty walking 500 metres?',
      'Do you have difficulty putting on footwear or clothing?',
      'Does your work involve kneeling or squatting?',
      'Do you carry heavy loads regularly?',
      'Do you work on uneven or hilly ground?',
      'Do you stand or walk for more than four hours a day?',
      'Past joint injury or surgery?',
      'Family history of arthritis?',
      'Diagnosed diabetes?',
      'Regular joint pain medication?',
    ];

    for (final label in itemLabels) {
      final item = find.ancestor(
        of: find.text(label),
        matching: find.byType(Column),
      );
      final answer = find.descendant(of: item.first, matching: find.text('No'));
      expect(answer, findsOneWidget, reason: 'no answer control for "$label"');
      await tester.tap(answer);
      await tester.pump();
    }

    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();

    // ── step 4: whole-body camera screen (FR-07/08/09) ────────────────────
    expect(find.text('Whole-body movement screen'), findsOneWidget);
    expect(
      find.textContaining('SIMULATED'),
      findsOneWidget,
      reason: 'a synthetic capture must be labelled on screen (PRD §1.2)',
    );

    const stage1Tests = ['Static posture', 'Sit to stand', 'Walking'];
    for (var i = 0; i < stage1Tests.length; i++) {
      final label = stage1Tests[i];
      // Let the synthetic engine deliver frames and the gate settle. The gate no
      // longer fails on unmeasurable lighting, so capture becomes available.
      await pumpFor(tester, const Duration(seconds: 1));
      await waitForCaptureAvailable(tester);

      expect(
        find.textContaining('Lighting'),
        findsWidgets,
        reason: 'the lighting check must be shown even when it cannot run',
      );
      expect(
        find.textContaining('not measured'),
        findsWidgets,
        reason: 'an unmeasured check is displayed with its own state',
      );

      await tester.tap(find.text('Start capture'));
      await pumpFor(tester, const Duration(seconds: 12));

      expect(
        find.textContaining('Re-record $label'),
        findsOneWidget,
        reason: '"$label" should have been captured and be re-recordable',
      );

      // The first two tests advance with NEXT; the third ends in the body map.
      if (i < stage1Tests.length - 1) {
        await tester.tap(find.text('NEXT'));
        await pumpFor(tester, const Duration(seconds: 1));
      }
    }

    await tester.tap(find.text('BUILD BODY MAP'));
    await pumpFor(tester, const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // ── step 5: body risk map (PRD §11.2 — worker confirms the target) ────
    expect(find.text('Body risk map'), findsOneWidget);
    expect(find.text('Select a joint to assess'), findsWidgets);

    await tester.tap(find.text('Select a joint to assess').first);
    await tester.pumpAndSettle();

    // ── step 6: targeted joint assessment (PRD §13) ───────────────────────
    expect(find.textContaining('Joint assessment'), findsWidgets);
    expect(find.textContaining('knee'), findsWidgets);

    // Record every movement test the knee protocol declares, including the
    // optional one: each has its own capture and its own quality report, and a
    // test that cannot be recorded is exactly what this flow exists to catch.
    var recorded = 0;
    while (find.text('Record test').evaluate().isNotEmpty) {
      await tester.tap(find.text('Record test').first);
      await pumpFor(tester, const Duration(seconds: 10));
      recorded++;
      expect(
        recorded,
        lessThan(10),
        reason: 'the record button is not turning into a re-record action',
      );
    }
    // TEMP DEBUG
    // ignore: avoid_print
    print('RECORDED=$recorded :: ' +
        find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .where((t) => t != null)
            .join(' | '));
    expect(recorded, greaterThanOrEqualTo(4));
    expect(find.text('Re-record'), findsWidgets);

    await tester.tap(find.text('RUN ASSESSMENT'));
    await pumpFor(tester, const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // ── step 7: result (PRD §18, §24.2) ──────────────────────────────────
    expect(find.text('Screening result'), findsOneWidget);
    expect(find.textContaining('not a diagnosis'), findsWidgets);
    expect(
      find.text('What could not contribute'),
      findsOneWidget,
      reason: 'branches that could not score are listed, not omitted',
    );

    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();

    // ── step 8: PDF report (FR-25, §24.1) ────────────────────────────────
    expect(find.text('Generate PDF'), findsOneWidget);
    await tester.tap(find.text('Generate PDF'));
    await tester.pumpAndSettle();

    final reports = Directory('${documents.path}/reports');
    expect(
      reports.existsSync(),
      isTrue,
      reason: 'the report should have been written to the documents directory',
    );
    final files = reports.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('.pdf'));
    expect(
      files.single.lengthSync(),
      greaterThan(1000),
      reason: 'a PDF with real content, not an empty placeholder',
    );

    // The report is also recorded against the screening, so the dashboard can
    // find it later (PRD §24.1).
    final reportRows = await database.query('report');
    expect(reportRows, hasLength(1));
    expect(reportRows.single['pdf_path'], files.single.path);
  });
}
