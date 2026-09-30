// Widget tests for the presentation rules the PRD makes binding.
//
// The Flutter template's counter test was removed when main.dart was rewritten:
// it pumped a `MyApp` that no longer exists, so it was a test of nothing that
// also failed to compile.
//
// What is tested here instead is the pair of rules a screen can break silently:
//
//   * PRD §19.2 — risk state is never colour-only, so RiskChip must render an
//     icon and a word for every band, including the "not assessed" state that
//     must never look like "no risk".
//   * PRD §26.5 — a missing measurement is never rendered as a number, so a
//     null MeasurementTile must say so.
//
// The full app is not pumped here on purpose: ArogyaApp opens the encrypted
// database and loads protocol assets, which is an integration concern covered by
// the registry, scoring and fusion suites. A widget test that half-boots the app
// and asserts on a spinner would test the test, not the product.

import 'package:arogya_ner/app/safety.dart';
import 'package:arogya_ner/app/strings.dart';
import 'package:arogya_ner/app/theme.dart';
import 'package:arogya_ner/domain/protocol/models.dart';
import 'package:arogya_ner/features/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wraps a widget in the two scopes every screen depends on.
Widget _host(Widget child, {AppLanguage language = AppLanguage.english}) {
  return StringsScope(
    language: language,
    strings: AppStrings(language),
    child: MaterialApp(
      theme: ArogyaTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('risk state is never colour alone (PRD §19.2)', () {
    testWidgets('a band renders a word and an icon, not just a colour',
        (tester) async {
      await tester.pumpWidget(_host(
        const RiskChip(
          presentation: RiskPresentation(
            label: 'Higher priority',
            icon: Icons.priority_high,
            color: Color(0xFFB71C1C),
            onColor: Colors.white,
          ),
        ),
      ));

      expect(find.text('Higher priority'), findsOneWidget);
      expect(find.byIcon(Icons.priority_high), findsOneWidget);
    });

    testWidgets('the unscored state is distinct from the lowest risk band',
        (tester) async {
      final notAssessed = RiskPresentation.forBand(null);

      expect(notAssessed.label, 'Not assessed');
      expect(
        notAssessed.label,
        isNot(contains('Lower')),
        reason: 'an unassessed joint must never read as low risk',
      );
      // A declared band with an unknown id must not be guessed at either.
      final unknown = RiskPresentation.forBand(
        const RiskBand(
          id: 'unmapped',
          minScore: 0,
          labelKey: '',
          actionKey: 'action.unknown',
        ),
      );
      expect(unknown.label, 'unmapped');
      expect(
        unknown.icon,
        isNot(notAssessed.icon),
        reason: 'an unrecognised band id must not be presented with the icon of '
            'a state that means something else',
      );
    });
  });

  group('a missing measurement is never a zero (PRD §26.5)', () {
    testWidgets('a null value reads "not measured"', (tester) async {
      await tester.pumpWidget(_host(
        const MeasurementTile(label: 'Knee flexion ROM', value: null),
      ));

      expect(find.text('not measured'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a measured value is formatted, with its unit and caveat',
        (tester) async {
      await tester.pumpWidget(_host(
        const MeasurementTile(
          label: 'Knee flexion ROM',
          value: 118.5,
          unit: '°',
          caveat: 'camera-derived',
        ),
      ));

      expect(find.text('118.5 °'), findsOneWidget);
      expect(find.text('camera-derived'), findsOneWidget);
      expect(find.text('not measured'), findsNothing);
    });
  });

  group('the screening-not-diagnosis boundary (PRD §1.2, FR-25)', () {
    testWidgets('the safety banner renders the versioned disclaimer',
        (tester) async {
      await tester.pumpWidget(_host(const SafetyBanner()));

      // Exact match: the full disclaimer also contains the phrase "not a
      // diagnosis", so a substring search here would match two widgets.
      expect(
        find.text('Screening support only. This is not a diagnosis.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('must interpret these results'),
        findsOneWidget,
        reason: 'the disclaimer is a clinical string and must be rendered in '
            'full, not paraphrased',
      );
    });

    testWidgets('the dense form stays short enough to embed', (tester) async {
      await tester.pumpWidget(_host(const SafetyBanner(dense: true)));

      expect(find.textContaining('not a diagnosis'), findsOneWidget);
      expect(find.textContaining('must interpret these results'), findsNothing);
    });

    test('the clinical string version is declared and separate from UI strings',
        () {
      expect(ClinicalStrings.version, isNotEmpty);
      expect(
        ClinicalStrings.lookup('disclaimer', 'en', 'text'),
        isNotNull,
        reason: 'the disclaimer is a clinical string and must resolve',
      );
      expect(
        ClinicalStrings.lookup('instrument', 'en', 'womac.pain.1'),
        isNull,
        reason: 'instrument wording is not transcribed before clinical sign-off '
            '(DECISIONS.md D5)',
      );
      expect(ClinicalStrings.isInstrumentWordingPending(), isTrue);
    });
  });

  group('interface strings are honest about coverage (PRD §20)', () {
    test('English is complete for the keys a screen needs', () {
      final strings = AppStrings(AppLanguage.english);
      for (final key in [
        'safety.banner',
        'home.new_screening',
        'result.indication',
        'report.generate',
      ]) {
        expect(strings.t(key), isNot(key), reason: '$key has no English string');
      }
    });

    test('a planned language has no table and falls back to English', () {
      expect(AppStrings.hasTranslationsFor(AppLanguage.mizo.code), isFalse);

      final strings = AppStrings(AppLanguage.mizo);
      expect(
        strings.t('home.new_screening'),
        AppStrings.en.t('home.new_screening'),
      );
      expect(AppLanguage.mizo.isPlanned, isTrue);
    });

    test('a language that has a table records the keys it is missing', () {
      // Assamese ships a partial table, which is exactly the case a release
      // check needs to see: a key with no translation falls back to English and
      // is recorded rather than silently accepted.
      final strings = AppStrings(AppLanguage.assamese);

      expect(
        strings.t('result.indication'),
        AppStrings.en.t('result.indication'),
      );
      expect(strings.missingKeys, contains('result.indication'));
      expect(AppLanguage.assamese.isPlanned, isFalse);
    });
  });
}
