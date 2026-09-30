// App theme and risk semantics (PRD §19.2, §19.3).
//
// PRD §19.2 requires "Color is supplementary; use text/icons for risk state",
// and §19.3 requires high contrast and readable typography. So a risk band is
// never represented by a colour alone anywhere in this app: every risk surface
// goes through [RiskPresentation], which always carries an icon and a text
// label alongside whatever colour is chosen.
//
// Large touch targets are also a §19.2 requirement, not a preference: field use
// happens on a phone held in one hand, often outdoors, sometimes with gloves.

import 'package:flutter/material.dart';

import '../domain/protocol/models.dart';

class ArogyaTheme {
  const ArogyaTheme._();

  /// Minimum interactive target, per PRD §19.2 "large touch targets".
  static const double minTouchTarget = 56;

  static const Color seed = Color(0xFF00696D);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: seed);
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: const Color(0xFFF6F8F8),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.comfortable,
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        elevation: 0,
      ),
      // Generous text scaling support: the field worker may be reading this in
      // daylight on a low-end screen.
      textTheme: base.textTheme.copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.4),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 15.5, height: 1.4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(minTouchTarget),
          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(minTouchTarget),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 14,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

/// Colour + icon + text for one risk state.
///
/// The three always travel together. A caller cannot render the colour without
/// also having the icon and the word, which is what makes §19.2's rule
/// structural rather than a convention someone has to remember.
class RiskPresentation {
  const RiskPresentation({
    required this.label,
    required this.icon,
    required this.color,
    required this.onColor,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color onColor;

  /// Presentation for a declared protocol risk band (PRD §11.2, §24.2).
  ///
  /// Bands are matched by the band's `id` from the protocol, not by score, so
  /// this stays correct when a joint's thresholds are re-derived from pilot
  /// data. An unrecognised band id falls back to a neutral, non-committal
  /// treatment rather than guessing a colour.
  static RiskPresentation forBand(RiskBand? band) {
    if (band == null) return notAssessed;
    return switch (band.id) {
      'low' => const RiskPresentation(
          label: 'Lower priority',
          icon: Icons.check_circle_outline,
          color: Color(0xFF1B5E20),
          onColor: Colors.white,
        ),
      'moderate' => const RiskPresentation(
          label: 'Moderate priority',
          icon: Icons.error_outline,
          color: Color(0xFFE65100),
          onColor: Colors.white,
        ),
      'high' => const RiskPresentation(
          label: 'Higher priority',
          icon: Icons.priority_high,
          color: Color(0xFFB71C1C),
          onColor: Colors.white,
        ),
      _ => RiskPresentation(
          label: band.bodyKeyOrId,
          icon: Icons.help_outline,
          color: const Color(0xFF455A64),
          onColor: Colors.white,
        ),
    };
  }

  /// The state that must never be rendered as "no risk".
  ///
  /// PRD §6.2 and §26.5: "not assessed" and "assessed as low risk" are
  /// different statements. This presentation exists so a screen has a distinct,
  /// deliberately un-colour-coded way to say the former.
  static const RiskPresentation notAssessed = RiskPresentation(
    label: 'Not assessed',
    icon: Icons.remove_circle_outline,
    color: Color(0xFF455A64),
    onColor: Colors.white,
  );

  /// A measurement that came from a synthetic engine rather than a patient.
  static const RiskPresentation synthetic = RiskPresentation(
    label: 'Simulated data',
    icon: Icons.science_outlined,
    color: Color(0xFF4527A0),
    onColor: Colors.white,
  );
}

extension on RiskBand {
  /// Band display fallback when an id is not one of the three known bands.
  String get bodyKeyOrId => labelKey.isEmpty ? id : labelKey;
}
