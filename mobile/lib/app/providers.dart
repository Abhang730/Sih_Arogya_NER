// Dependency injection and in-progress screening state.
//
// Everything asynchronous that a screen needs (database, protocol registry,
// model manifest, fusion config) is a FutureProvider, so a screen renders a real
// loading state instead of reaching for a null and crashing. That matters more
// here than in a typical app: the registry and the manifest are the two things
// that decide what the product is allowed to claim, and a screen that ran
// without them would be a screen that invented defaults.
//
// The in-progress screening lives in a Notifier rather than in the database
// alone, because a screening is a multi-screen conversation and a worker may
// move backwards. It is written to the database at each completed stage
// (draft save / resume, PRD §30 Phase 2).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/fusion.dart';
import '../ai/stage1_localizer.dart';
import '../ai/tflite_branch.dart';
import '../data/db/database.dart';
import '../data/records.dart';
import '../data/repositories.dart';
import '../domain/protocol/registry.dart';
import '../domain/protocol/scoring.dart';
import '../screening/assessment_engine.dart';
import '../screening/stage1_questionnaire.dart';
import '../wearable/imu_features.dart';
import 'strings.dart';

/// The open local database, with its security posture.
final databaseProvider = FutureProvider<OpenedDatabase>((ref) async {
  return openArogyaDatabase();
});

/// Repositories bound to the open database.
final repositoriesProvider = FutureProvider<Repositories>((ref) async {
  final opened = await ref.watch(databaseProvider.future);
  return Repositories.forDatabase(opened.database);
});

/// The registry and landmark topology, loaded from the bundled protocol set.
final registryProvider = FutureProvider<ProtocolRegistry>((ref) async {
  return ProtocolRegistry.load();
});

/// The generated model manifest. Absent or malformed is a valid state (no model
/// has been trained yet), handled inside [ModelManifest.load].
final manifestProvider = FutureProvider<ModelManifest>((ref) async {
  return ModelManifest.load();
});

/// Fusion coefficients, or the declared uncalibrated default.
final fusionConfigProvider = FutureProvider<FusionConfig>((ref) async {
  return FusionConfig.load();
});

/// The joint assessment engine, wired with the registry, manifest and config.
final assessmentEngineProvider =
    FutureProvider<JointAssessmentEngine>((ref) async {
  final registry = await ref.watch(registryProvider.future);
  final manifest = await ref.watch(manifestProvider.future);
  final fusionConfig = await ref.watch(fusionConfigProvider.future);
  return JointAssessmentEngine(
    registry: registry,
    manifest: manifest,
    fusionConfig: fusionConfig,
  );
});

/// Signed-in worker, or null.
class AuthNotifier extends Notifier<Worker?> {
  @override
  Worker? build() => null;

  void signIn(Worker worker) => state = worker;

  void signOut() => state = null;
}

final authProvider = NotifierProvider<AuthNotifier, Worker?>(AuthNotifier.new);

/// Selected interface language (PRD §20).
class LanguageNotifier extends Notifier<AppLanguage> {
  @override
  AppLanguage build() => AppLanguage.english;

  void select(AppLanguage language) => state = language;
}

final languageProvider =
    NotifierProvider<LanguageNotifier, AppLanguage>(LanguageNotifier.new);

/// One in-progress screening.
class ScreeningSessionState {
  const ScreeningSessionState({
    this.patient,
    this.screening,
    this.answers,
    this.stage1RiskMap,
    this.stage1PoseEngineId,
    this.stage1Synthetic = false,
    this.jointOutcome,
    this.questionnaireScore,
    this.jointSide,
    this.jointId,
    this.imagingAttached = false,
    this.imuTrial,
  });

  final Patient? patient;
  final Screening? screening;
  final Stage1Answers? answers;
  final JointRiskMap? stage1RiskMap;
  final String? stage1PoseEngineId;

  /// True when the Stage-1 capture used generated landmarks. Travels with the
  /// session so the result screen and the report cannot present simulated data
  /// as a measurement (PRD §1.2).
  final bool stage1Synthetic;

  final JointAssessmentOutcome? jointOutcome;
  final QuestionnaireScore? questionnaireScore;
  final String? jointSide;
  final String? jointId;
  final bool imagingAttached;

  /// The most recent Motion Pod trial, collected on the wearable screen and
  /// consumed by the next assessment run. Null means no pod was used, which is
  /// a supported configuration (PRD §14).
  final ImuTrial? imuTrial;

  bool get hasPatient => patient != null;
  bool get hasAnswers => answers != null && answers!.isComplete;
  bool get hasStage1 => stage1RiskMap != null;
  bool get hasJoint => jointOutcome != null;

  /// Stage labels completed so far, in order. Drives the home screen's
  /// resume-where-you-left-off affordance.
  List<String> get completedStages => [
        if (hasPatient) 'patient',
        if (hasAnswers) 'questionnaire',
        if (hasStage1) 'stage1',
        if (hasJoint) 'joint',
      ];

  /// True when any part of this screening used simulated data. Drives a
  /// persistent banner on every downstream screen.
  bool get usedSimulatedData =>
      stage1Synthetic || (jointOutcome?.syntheticCapture ?? false);

  ScreeningSessionState copyWith({
    Patient? patient,
    Screening? screening,
    Stage1Answers? answers,
    JointRiskMap? stage1RiskMap,
    String? stage1PoseEngineId,
    bool? stage1Synthetic,
    JointAssessmentOutcome? jointOutcome,
    QuestionnaireScore? questionnaireScore,
    String? jointSide,
    String? jointId,
    bool? imagingAttached,
    ImuTrial? imuTrial,
  }) =>
      ScreeningSessionState(
        patient: patient ?? this.patient,
        screening: screening ?? this.screening,
        answers: answers ?? this.answers,
        stage1RiskMap: stage1RiskMap ?? this.stage1RiskMap,
        stage1PoseEngineId: stage1PoseEngineId ?? this.stage1PoseEngineId,
        stage1Synthetic: stage1Synthetic ?? this.stage1Synthetic,
        jointOutcome: jointOutcome ?? this.jointOutcome,
        questionnaireScore: questionnaireScore ?? this.questionnaireScore,
        jointSide: jointSide ?? this.jointSide,
        jointId: jointId ?? this.jointId,
        imagingAttached: imagingAttached ?? this.imagingAttached,
        imuTrial: imuTrial ?? this.imuTrial,
      );
}

class ScreeningSessionNotifier extends Notifier<ScreeningSessionState> {
  @override
  ScreeningSessionState build() => const ScreeningSessionState();

  void startWith(Patient patient, Screening screening) {
    state = ScreeningSessionState(patient: patient, screening: screening);
  }

  void setAnswers(Stage1Answers answers) {
    state = state.copyWith(answers: answers);
  }

  void setStage1({
    required JointRiskMap riskMap,
    required String poseEngineId,
    required bool synthetic,
  }) {
    state = state.copyWith(
      stage1RiskMap: riskMap,
      stage1PoseEngineId: poseEngineId,
      stage1Synthetic: synthetic,
    );
  }

  void selectJoint({required String jointId, required String side}) {
    state = state.copyWith(jointId: jointId, jointSide: side);
  }

  /// Records a joint outcome under a specific joint+side.
  ///
  /// A screening may assess more than one joint (PRD §11.2 lets the worker
  /// confirm or override the suggested target), so a second assessment replaces
  /// the displayed one rather than being merged with it.
  void setJointOutcome(
    JointAssessmentOutcome outcome, {
    QuestionnaireScore? questionnaireScore,
  }) {
    state = state.copyWith(
      jointOutcome: outcome,
      questionnaireScore: questionnaireScore,
      jointId: outcome.jointId,
      jointSide: outcome.side,
    );
  }

  void setImagingAttached(bool attached) {
    state = state.copyWith(imagingAttached: attached);
  }

  /// Records (or replaces) the joint questionnaire score for this session.
  ///
  /// Stored separately from [setJointOutcome] so a worker can answer the
  /// instrument before running the assessment, and edit it afterwards, without
  /// the score being silently dropped by whichever call happens second.
  void setQuestionnaireScore(QuestionnaireScore score) {
    state = state.copyWith(questionnaireScore: score);
  }

  void setImuTrial(ImuTrial trial) {
    state = state.copyWith(imuTrial: trial);
  }

  void reset() => state = const ScreeningSessionState();
}

final screeningSessionProvider =
    NotifierProvider<ScreeningSessionNotifier, ScreeningSessionState>(
  ScreeningSessionNotifier.new,
);

/// Whether the database on this platform is encrypted, for the Settings warning.
final databaseSecurityProvider = Provider<DatabaseSecurity>((ref) {
  final opened = ref.watch(databaseProvider);
  return opened.maybeWhen(
    data: (db) => db.security,
    // Unknown while loading, or when the database could not be opened at all.
    orElse: () => DatabaseSecurity.unencryptedDevelopmentFallback,
  );
});
