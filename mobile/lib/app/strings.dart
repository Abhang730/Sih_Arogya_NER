// Localization (PRD §20).
//
// PRD §20.2 draws a line that is easy to blur in code and expensive to blur in
// law: "Clinical questionnaire strings must be versioned separately from
// ordinary UI strings."
//
// So there are two namespaces here, not one:
//
//   * [AppStrings.ui] — ordinary interface text. Free to change with a release.
//   * [ClinicalStrings] — instrument wording and safety text. Carries its own
//     [version], and the version is stamped into every stored screening record.
//     Changing a clinical string without bumping the version is a defect,
//     because a stored score would then be attributable to wording nobody can
//     reproduce.
//
// PRD §20.3: TTS is an accessibility layer, not a reasoning engine, and prompts
// must be pre-approved for the exact text. There is therefore no generated
// speech here — only an optional recorded/approved prompt key per string, which
// is null until an approved prompt exists. Inventing prompts at runtime would
// breach §20.3.
//
// Coverage honesty (PRD §20.1): English is core, Hindi is "core expansion",
// Assamese is the "initial NER prototype". Every other NER language is marked
// planned, and [isPlanned] is surfaced in Settings so the app never implies
// coverage it does not have.

import 'package:flutter/widgets.dart';

/// One language, with the PRD's own maturity stage attached.
enum AppLanguage {
  english('en', 'English', StringCoverage.core),
  hindi('hi', 'हिन्दी', StringCoverage.coreExpansion),
  assamese('as', 'অসমীয়া', StringCoverage.initialPrototype),
  bengali('bn', 'বাংলা', StringCoverage.planned),
  manipuri('mni', 'মৈতৈলোন্', StringCoverage.planned),
  khasi('kha', 'Khasi', StringCoverage.planned),
  garo('grt', 'Garo', StringCoverage.planned),
  mizo('lus', 'Mizo', StringCoverage.planned),
  nagamese('nag', 'Nagamese', StringCoverage.planned);

  const AppLanguage(this.code, this.label, this.coverage);

  final String code;
  final String label;
  final String coverage;

  /// True when the PRD lists this language as planned rather than built. The
  /// app must not present a planned language as usable.
  bool get isPlanned => coverage == StringCoverage.planned;

  /// Whether UI strings exist for this language today.
  bool get hasTranslations => AppStrings.hasTranslationsFor(code);

  static AppLanguage fromCode(String? code) =>
      AppLanguage.values.firstWhere((l) => l.code == code, orElse: () => english);
}

class StringCoverage {
  const StringCoverage._();

  static const String core = 'core';
  static const String coreExpansion = 'core_expansion';
  static const String initialPrototype = 'initial_ner_prototype';
  static const String planned = 'planned';
}

/// Ordinary interface strings, keyed by locale.
class AppStrings {
  AppStrings(this.language);

  final AppLanguage language;

  static final AppStrings en = AppStrings(AppLanguage.english);

  /// Whether a translation table exists for [code].
  static bool hasTranslationsFor(String code) => _ui.containsKey(code);

  String t(String key) {
    final table = _ui[language.code] ?? _ui['en']!;
    final value = table[key];
    if (value != null) return value;
    // Falling back to English is required (there is no acceptable blank label),
    // but it is not silent: [missingKeys] records it so a release check can
    // assert zero misses on a language the PRD calls "core".
    if (language.code != 'en') _missing.add(key);
    return _ui['en']![key] ?? key;
  }

  String tArgs(String key, Map<String, String> args) {
    var value = t(key);
    args.forEach((name, replacement) {
      value = value.replaceAll('{$name}', replacement);
    });
    return value;
  }

  final Set<String> _missing = <String>{};

  /// Interface keys that had no translation and fell back to English.
  Set<String> get missingKeys => Set.unmodifiable(_missing);

  static const Map<String, Map<String, String>> _ui = {
    'en': _en,
    'hi': _hi,
    'as': _as,
  };

  // ── English ────────────────────────────────────────────────────────────
  static const Map<String, String> _en = {
    'app.title': 'Arogya-NER',
    'app.tagline': 'Smart Clinic in a Pocket',

    'action.next': 'NEXT',
    'action.back': 'Back',
    'action.save': 'Save',
    'action.cancel': 'Cancel',
    'action.retry': 'Try again',
    'action.continue': 'Continue',

    'login.title': 'Worker sign in',
    'login.worker_id': 'Worker ID',
    'login.passcode': 'Passcode',
    'login.submit': 'Sign in',
    'login.offline_notice':
        'Sign-in works without internet. Your access is verified on this device.',
    'login.error.empty': 'Enter your Worker ID and passcode.',
    'login.error.invalid': 'That Worker ID and passcode did not match.',
    'login.error.locked':
        'Too many failed attempts. Ask your supervisor to re-provision this device.',

    'home.title': 'Home',
    'home.new_screening': 'New screening',
    'home.drafts': 'Drafts',
    'home.recent': 'Recent screenings',
    'home.no_recent': 'No screenings recorded on this device yet.',
    'home.sync_status': 'Sync status',
    'home.history': 'History',
    'home.settings': 'Settings',

    'patient.title': 'Patient registration',
    'patient.name': 'Name',
    'patient.age': 'Age (years)',
    'patient.sex': 'Sex',
    'patient.sex.female': 'Female',
    'patient.sex.male': 'Male',
    'patient.sex.other': 'Other',
    'patient.sex.unspecified': 'Not specified',
    'patient.height': 'Height (cm)',
    'patient.weight': 'Weight (kg)',
    'patient.district': 'District',
    'patient.identity': 'Protected identity reference',
    'patient.identity_help':
        'Optional. Stored encrypted and masked. The Arogya Patient ID below is '
            'what is used everywhere else.',
    'patient.arogya_id': 'Arogya Patient ID',
    'patient.arogya_id_help':
        'Generated on this device. This is the operational identifier for this '
            'patient; the protected reference above is never used for lookup.',
    'patient.consent': 'Consent to store screening data',
    'patient.consent_detail':
        'Screening data is stored on this device and, when connectivity returns, '
            'synced to the health system. Raw video is not retained.',
    'patient.bmi': 'BMI',
    'patient.error.name': 'Enter the patient name.',
    'patient.error.age': 'Enter an age between 1 and 120.',
    'patient.error.consent': 'Consent must be recorded before screening data is stored.',

    'questionnaire.title': 'Whole-body questionnaire',
    'questionnaire.section.pain': 'Where does it hurt?',
    'questionnaire.section.mobility': 'General mobility',
    'questionnaire.section.exposure': 'Work and daily activities',
    'questionnaire.section.history': 'Medical history',
    'questionnaire.section.symptom': 'Current symptom scale',
    'questionnaire.pain_hint': 'Tap every area that hurts. Tap again to clear.',
    'questionnaire.pain_score': 'Worst pain in the last 24 hours',
    'questionnaire.progress': '{answered} of {total} answered',
    'questionnaire.mobility.rise': 'Do you have difficulty rising from a chair?',
    'questionnaire.mobility.stairs': 'Do you have difficulty with stairs?',
    'questionnaire.mobility.walk': 'Do you have difficulty walking 500 metres?',
    'questionnaire.mobility.dressing':
        'Do you have difficulty putting on footwear or clothing?',
    'questionnaire.exposure.kneeling': 'Does your work involve kneeling or squatting?',
    'questionnaire.exposure.loading': 'Do you carry heavy loads regularly?',
    'questionnaire.exposure.terrain': 'Do you work on uneven or hilly ground?',
    'questionnaire.exposure.hours':
        'Do you stand or walk for more than four hours a day?',
    'questionnaire.history.injury': 'Past joint injury or surgery?',
    'questionnaire.history.arthritis': 'Family history of arthritis?',
    'questionnaire.history.diabetes': 'Diagnosed diabetes?',
    'questionnaire.history.medication': 'Regular joint pain medication?',
    'questionnaire.answer.yes': 'Yes',
    'questionnaire.answer.no': 'No',
    'questionnaire.answer.unsure': 'Not sure',

    'camera.title': 'Whole-body movement screen',
    'camera.setup_title': 'Camera setup',
    'camera.quality_title': 'Capture quality',
    'camera.start': 'Start capture',
    'camera.stop': 'Stop capture',
    'camera.capturing': 'Capturing…',
    'camera.quality_blocked':
        'Capture is blocked until every quality check passes.',
    'camera.synthetic_warning':
        'This build has no camera pose engine available on this device, so the '
            'landmarks below are SIMULATED. They are not measurements of this patient '
            'and must not be read as such.',

    'risk.title': 'Body risk map',
    'risk.suggested': 'Suggested for closer assessment',
    'risk.none_suggested': 'No joint marker was scored, so nothing is suggested.',
    'risk.not_assessed': 'Not assessed',
    'risk.coverage_note':
        'A joint shown as "not assessed" has no validated model. That is not the '
            'same as low risk.',
    'risk.reported_pain': 'Patient-reported pain',
    'risk.select_joint': 'Select a joint to assess',

    'joint.title': 'Joint assessment',
    'joint.side': 'Which side?',
    'joint.side.right': 'Right',
    'joint.side.left': 'Left',
    'joint.side.both': 'Both',
    'joint.tests': 'Movement tests',
    'joint.questionnaire': 'Validated questionnaire',
    'joint.questionnaire_unavailable':
        'This joint has no clinically signed-off questionnaire, so no questions '
            'are shown. Screening falls back to the symptom screen.',
    'joint.wearable': 'Motion Pod',
    'joint.record_test': 'Record test',
    'joint.test_complete': 'Test recorded',

    'womac.title': 'WOMAC',
    'womac.intro':
        'WOMAC 3.1. 24 questions about the last 48 hours. Answer for the side '
            'being assessed.',
    'womac.subscale.pain': 'Pain',
    'womac.subscale.stiffness': 'Stiffness',
    'womac.subscale.function': 'Function',
    'womac.score': 'WOMAC {total} of {max}',
    'womac.incomplete': '{answered} of {total} answered — total not reported '
        'until every question is answered.',

    'wearable.title': 'Motion Pod',
    'wearable.scan': 'Find Motion Pod',
    'wearable.placement': 'Placement',
    'wearable.calibrate': 'Calibrate',
    'wearable.live_quality': 'Live signal quality',
    'wearable.connected': 'Connected',
    'wearable.disconnected': 'Not connected',
    'wearable.simulated':
        'No Motion Pod hardware is present, so the signal below is SIMULATED.',

    'imaging.title': 'Existing imaging and reports',
    'imaging.attach': 'Attach a photo or report',
    'imaging.none': 'No imaging attached.',
    'imaging.role':
        'Attachments are supporting evidence only. Nothing here is interpreted '
            'by the app.',

    'result.title': 'Screening result',
    'result.indication': 'Screening indication',
    'result.contributors': 'What contributed',
    'result.not_contributing': 'What could not contribute',
    'result.referral': 'Recommended action',
    'result.guidance': 'Preventive guidance',
    'result.agreement': 'Branch agreement {percent}%',
    'result.model_versions': 'Model versions',
    'result.no_score':
        'No combined indication could be produced from this assessment. The '
            'measurements that were taken are still valid and should be reviewed.',

    'report.title': 'Report',
    'report.generate': 'Generate PDF',
    'report.share': 'Share',
    'report.print': 'Print',

    'history.title': 'History',
    'history.search': 'Search by Arogya Patient ID or name',
    'history.empty': 'No records on this device match.',

    'settings.title': 'Settings',
    'settings.language': 'Language',
    'settings.language_planned':
        '{language} is planned, not built. Strings fall back to English.',
    'settings.device': 'Device',
    'settings.sync': 'Sync',
    'settings.sync_now': 'Sync now',
    'settings.worker_profile': 'Worker profile',
    'settings.sign_out': 'Sign out',
    'settings.clinical_strings': 'Clinical string version',

    'sync.pending': '{count} waiting to sync',
    'sync.none': 'Everything is synced.',
    'sync.offline': 'Offline — records are stored on this device',
    'sync.online': 'Online',
    'sync.done': 'Sync complete',
    'sync.failed': 'Sync failed: {error}',

    'safety.banner':
        'Screening support only. This is not a diagnosis.',
    'safety.detail':
        'Arogya-NER indicates likelihood and recommends next steps. It does not '
            'diagnose osteoarthritis or any other condition. A qualified clinician '
            'must interpret these results.',
  };

  // ── Hindi (core expansion) ─────────────────────────────────────────────
  static const Map<String, String> _hi = {
    'app.tagline': 'जेब में स्मार्ट क्लिनिक',
    'action.next': 'आगे',
    'action.back': 'पीछे',
    'home.new_screening': 'नई जाँच',
    'home.history': 'इतिहास',
    'home.settings': 'सेटिंग्स',
    'safety.banner': 'केवल जाँच सहायता। यह निदान नहीं है।',
  };

  // ── Assamese (initial NER prototype) ───────────────────────────────────
  static const Map<String, String> _as = {
    'app.tagline': 'পকেটত স্মাৰ্ট ক্লিনিক',
    'action.next': 'পৰৱৰ্তী',
    'action.back': 'পিছলৈ',
    'home.new_screening': 'নতুন পৰীক্ষা',
    'home.history': 'ইতিহাস',
    'home.settings': 'ছেটিংছ',
    'safety.banner': 'কেৱল পৰীক্ষাৰ সহায়। এইটো ৰোগ নিৰ্ণয় নহয়।',
  };
}

/// Clinical wording, versioned independently of the interface (PRD §20.2).
///
/// The version string is written into every stored screening record, so a score
/// can always be traced back to the exact instrument wording that produced it.
class ClinicalStrings {
  const ClinicalStrings._();

  /// bump on ANY change to the clinical string tables below.
  static const String version = '2026.09.1';

  /// The safety disclaimer is a clinical string, not interface copy: PRD §1.2
  /// makes it binding, and §28 FR-25 requires it at result and report
  /// boundaries.
  static const Map<String, String> disclaimer = {
    'en': 'Screening support only. This is not a diagnosis.\n\n'
        'Arogya-NER indicates likelihood and recommends next steps. It does not '
        'diagnose osteoarthritis or any other condition. A qualified clinician '
        'must interpret these results.',
    'hi': 'केवल जाँच सहायता। यह निदान नहीं है।\n\n'
        'अरोग्य-एनईआर संभावना बताता है और अगले कदम सुझाता है। यह ऑस्टियोआर्थराइटिस '
        'या किसी अन्य रोग का निदान नहीं करता। इन परिणामों की व्याख्या योग्य '
        'चिकित्सक द्वारा की जानी चाहिए।',
    'as': 'কেৱল পৰীক্ষাৰ সহায়। এইটো ৰোগ নিৰ্ণয় নহয়।\n\n'
        'অাৰোগ্য-এনইআৰে সম্ভাৱনা সূচায় আৰু পৰৱৰ্তী পদক্ষেপৰ পৰামৰ্শ দিয়ে। ই '
        'অষ্টিঅ’আৰ্থ্ৰাইটিছ বা অন্য কোনো ৰোগ নিৰ্ণয় নকৰে। ফলাফল এজন যোগ্য '
        'চিকিৎসকে ব্যাখ্যা কৰিব লাগিব।',
  };

  /// WOMAC item wording.
  ///
  /// Deliberately EMPTY, and this is a correctness property rather than an
  /// omission. DECISIONS.md D5/D6 and docs/DECISIONS.md record that instrument
  /// wording is not transcribed until clinical sign-off; the app stores only the
  /// item ids from the protocol and looks the phrasing up here. An empty table
  /// means the UI shows the item id and a "wording pending" notice, which is
  /// honest. Paraphrasing a licensed instrument would not be.
  static const Map<String, Map<String, String>> instrument = {};

  /// Resolves a clinical string, or null when it has not been signed off.
  static String? lookup(String namespace, String locale, String key) {
    if (namespace == 'disclaimer') {
      return disclaimer[locale] ?? disclaimer['en'];
    }
    if (namespace == 'instrument') {
      return instrument[locale]?[key] ?? instrument['en']?[key];
    }
    return null;
  }

  /// True when the app must show a "wording pending clinical sign-off" notice
  /// instead of item text.
  static bool isInstrumentWordingPending() => instrument.isEmpty;
}

/// Makes the active language available to the widget tree.
class StringsScope extends InheritedWidget {
  const StringsScope({
    super.key,
    required this.strings,
    required this.language,
    required super.child,
  });

  final AppStrings strings;
  final AppLanguage language;

  static StringsScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<StringsScope>();
    assert(scope != null, 'StringsScope is missing above this widget.');
    return scope!;
  }

  static AppStrings stringsOf(BuildContext context) => of(context).strings;

  @override
  bool updateShouldNotify(StringsScope oldWidget) =>
      oldWidget.language != language || oldWidget.strings != strings;
}

/// Convenience accessors used by every screen.
///
/// [s] is a method rather than a getter on purpose: `context.s('key')` reads as
/// a localisation lookup at the call site, so a missed translation is obvious
/// in review.
extension StringsX on BuildContext {
  AppStrings get strings => StringsScope.stringsOf(this);

  String s(String key) => StringsScope.stringsOf(this).t(key);

  String sArgs(String key, Map<String, String> args) =>
      StringsScope.stringsOf(this).tArgs(key, args);
}
