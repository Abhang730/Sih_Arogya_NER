// Protocol domain model (PRD §12.1).
//
// This mirrors protocols/schema/joint_protocol.schema.json one-to-one. The app
// is configuration-driven on purpose: adding a joint must not require editing
// screen code (PRD §29 "Maintainability"), so screens read these objects rather
// than branching on joint names.
//
// Parsing is deliberately strict about the fields the product depends on and
// tolerant about optional ones, because a provisioned device may hold a
// protocol older or newer than the app build.

import 'package:collection/collection.dart';

// ─────────────────────────────────────────────────────────── landmark core ──

class LandmarkDef {
  const LandmarkDef({
    required this.index,
    required this.key,
    required this.name,
    required this.region,
  });

  final int index;
  final String key;
  final String name;
  final String region;

  factory LandmarkDef.fromJson(Map<String, dynamic> json) => LandmarkDef(
        index: json['index'] as int,
        key: json['key'] as String,
        name: json['name'] as String,
        region: json['region'] as String,
      );
}

class QualityGateSpec {
  const QualityGateSpec({
    required this.requiredRegions,
    required this.referenceLandmarks,
    required this.defaultMinLikelihood,
    required this.lightingMetric,
    required this.defaultMinLighting,
  });

  /// PRD §9.4 — head, shoulders, hips, knees, ankles, lighting, framing, pose
  /// confidence must all pass before Stage-1 capture is accepted.
  final List<String> requiredRegions;
  final Map<String, List<String>> referenceLandmarks;
  final double defaultMinLikelihood;
  final String lightingMetric;
  final double defaultMinLighting;

  factory QualityGateSpec.fromJson(Map<String, dynamic> json) {
    final refs = <String, List<String>>{};
    final raw = json['reference_landmarks'];
    if (raw is Map) {
      raw.forEach((key, value) {
        refs[key as String] = (value as List).cast<String>();
      });
    }
    return QualityGateSpec(
      requiredRegions: (json['required_regions'] as List).cast<String>(),
      referenceLandmarks: refs,
      defaultMinLikelihood: (json['default_min_likelihood'] as num).toDouble(),
      lightingMetric: json['lighting_metric'] as String,
      defaultMinLighting: (json['default_min_lighting'] as num).toDouble(),
    );
  }
}

class LandmarkTopology {
  const LandmarkTopology({
    required this.topology,
    required this.landmarkCount,
    required this.landmarks,
    required this.qualityGate,
  });

  final String topology;
  final int landmarkCount;
  final List<LandmarkDef> landmarks;
  final QualityGateSpec qualityGate;

  LandmarkDef? byKey(String key) =>
      landmarks.firstWhereOrNull((l) => l.key == key);

  /// Index lookup used by the feature extractor to pull raw values out of a
  /// pose frame in O(1) rather than scanning the list per landmark.
  Map<String, int> get indexByKey =>
      {for (final l in landmarks) l.key: l.index};

  factory LandmarkTopology.fromJson(Map<String, dynamic> json) {
    final qualityGate = json['quality_gate'];
    return LandmarkTopology(
      topology: json['topology'] as String,
      landmarkCount: json['landmark_count'] as int,
      landmarks: (json['landmarks'] as List)
          .map((e) => LandmarkDef.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      qualityGate: qualityGate is Map<String, dynamic>
          ? QualityGateSpec.fromJson(qualityGate)
          : const QualityGateSpec(
              requiredRegions: ['head', 'shoulder', 'pelvis', 'knee', 'ankle'],
              referenceLandmarks: {},
              defaultMinLikelihood: 0.5,
              lightingMetric: 'mean_luma_of_roi',
              defaultMinLighting: 0.25,
            ),
    );
  }
}

// ──────────────────────────────────────────────────────────── questionnaire ──

/// PRD §1.2 / §26.5. A questionnaire that has not been signed off must never be
/// presented to a worker, because inventing or paraphrasing a licensed
/// instrument's items is a clinical-governance decision, not an engineering one.
enum QuestionnaireStatus {
  specified,
  pendingClinicalSignOff;

  static QuestionnaireStatus fromWire(String? value) => switch (value) {
        'specified' => QuestionnaireStatus.specified,
        'pending_clinical_sign_off' => QuestionnaireStatus.pendingClinicalSignOff,
        _ => QuestionnaireStatus.pendingClinicalSignOff,
      };

  String get wire => switch (this) {
        QuestionnaireStatus.specified => 'specified',
        QuestionnaireStatus.pendingClinicalSignOff => 'pending_clinical_sign_off',
      };
}

class QuestionnaireItem {
  const QuestionnaireItem({
    required this.id,
    required this.subscale,
    required this.textKey,
    this.voicePromptKey,
  });

  final String id;
  final String subscale;
  final String textKey;
  final String? voicePromptKey;

  factory QuestionnaireItem.fromJson(Map<String, dynamic> json) =>
      QuestionnaireItem(
        id: json['id'] as String,
        subscale: json['subscale'] as String,
        textKey: json['text_key'] as String,
        voicePromptKey: json['voice_prompt_key'] as String?,
      );
}

class ResponseOption {
  const ResponseOption({required this.value, required this.textKey});

  final int value;
  final String textKey;

  factory ResponseOption.fromJson(Map<String, dynamic> json) => ResponseOption(
        value: json['value'] as int,
        textKey: json['text_key'] as String,
      );
}

class Subscale {
  const Subscale({required this.name, required this.min, required this.max});

  final String name;
  final double min;
  final double max;

  factory Subscale.fromJson(Map<String, dynamic> json) => Subscale(
        name: json['name'] as String,
        min: (json['min'] as num).toDouble(),
        max: (json['max'] as num).toDouble(),
      );
}

class SeverityBand {
  const SeverityBand({
    required this.max,
    required this.labelKey,
    required this.validated,
    this.source,
  });

  final double max;
  final String labelKey;

  /// False means the band is a configurable display bucket, not a clinical
  /// cut-off, and must be rendered as such (PRD §1.2).
  final bool validated;
  final String? source;

  factory SeverityBand.fromJson(Map<String, dynamic> json) => SeverityBand(
        max: (json['max'] as num).toDouble(),
        labelKey: json['label_key'] as String,
        validated: json['validated'] as bool? ?? false,
        source: json['source'] as String?,
      );
}

enum ScoreDirection { higherIsWorse, higherIsBetter }

class QuestionnaireScoring {
  const QuestionnaireScoring({
    required this.responseOptions,
    required this.subscales,
    required this.totalMin,
    required this.totalMax,
    required this.direction,
    required this.normalisation,
    required this.severityBands,
  });

  final List<ResponseOption> responseOptions;
  final List<Subscale> subscales;
  final double totalMin;
  final double totalMax;
  final ScoreDirection direction;
  final String normalisation;
  final List<SeverityBand> severityBands;

  Subscale? subscale(String name) =>
      subscales.firstWhereOrNull((s) => s.name == name);

  bool get hasValidatedBands => severityBands.any((b) => b.validated);

  factory QuestionnaireScoring.fromJson(Map<String, dynamic> json) {
    final total = json['total'] as Map<String, dynamic>;
    final bands = json['severity_bands'];
    return QuestionnaireScoring(
      responseOptions: (json['response_options'] as List)
          .map((e) => ResponseOption.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      subscales: (json['subscales'] as List)
          .map((e) => Subscale.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      totalMin: (total['min'] as num).toDouble(),
      totalMax: (total['max'] as num).toDouble(),
      direction: (json['direction'] as String) == 'higher_is_better'
          ? ScoreDirection.higherIsBetter
          : ScoreDirection.higherIsWorse,
      normalisation: json['normalisation'] as String? ?? 'none',
      severityBands: bands is List
          ? bands
              .map((e) => SeverityBand.fromJson(e as Map<String, dynamic>))
              .toList(growable: false)
          : const [],
    );
  }
}

class ClinicalQuestionnaire {
  const ClinicalQuestionnaire({
    required this.instrument,
    required this.instrumentVersion,
    required this.status,
    required this.items,
    this.scoring,
    this.referenceInstrument,
    this.licenceNote,
  });

  final String instrument;
  final String instrumentVersion;
  final QuestionnaireStatus status;
  final List<QuestionnaireItem> items;
  final QuestionnaireScoring? scoring;
  final String? referenceInstrument;
  final String? licenceNote;

  /// The worker-facing gate. A pending instrument has no questions to show, so
  /// the UI must fall back to the Stage-1 symptom screen instead (PRD §1.2).
  bool get isUsable => status == QuestionnaireStatus.specified && scoring != null && items.isNotEmpty;

  List<QuestionnaireItem> itemsFor(String subscale) =>
      items.where((i) => i.subscale == subscale).toList(growable: false);

  factory ClinicalQuestionnaire.fromJson(Map<String, dynamic> json) {
    final scoring = json['scoring'];
    final items = json['items'];
    return ClinicalQuestionnaire(
      instrument: json['instrument'] as String,
      instrumentVersion: json['instrument_version'] as String,
      status: QuestionnaireStatus.fromWire(json['status'] as String?),
      items: items is List
          ? items
              .map((e) => QuestionnaireItem.fromJson(e as Map<String, dynamic>))
              .toList(growable: false)
          : const [],
      scoring: scoring is Map<String, dynamic>
          ? QuestionnaireScoring.fromJson(scoring)
          : null,
      referenceInstrument: json['reference_instrument'] as String?,
      licenceNote: json['licence_note'] as String?,
    );
  }
}

// ─────────────────────────────────────────────────────────── protocol parts ──

class ProtocolDisplay {
  const ProtocolDisplay({
    required this.title,
    required this.shortTitle,
    required this.bodyMapRegion,
    required this.lateralityRequired,
  });

  final String title;
  final String shortTitle;
  final String bodyMapRegion;
  final bool lateralityRequired;

  factory ProtocolDisplay.fromJson(Map<String, dynamic> json) => ProtocolDisplay(
        title: json['title'] as String,
        shortTitle: json['short_title'] as String,
        bodyMapRegion: json['body_map_region'] as String,
        lateralityRequired: json['laterality_required'] as bool,
      );
}

/// PRD §12.2 maturity. Drives what the UI is allowed to promise.
enum ProtocolStatus {
  mvp,
  platformReady,
  future;

  static ProtocolStatus fromWire(String? v) => switch (v) {
        'mvp' => ProtocolStatus.mvp,
        'platform_ready' => ProtocolStatus.platformReady,
        'future' => ProtocolStatus.future,
        _ => ProtocolStatus.future,
      };

  String get wire => switch (this) {
        ProtocolStatus.mvp => 'mvp',
        ProtocolStatus.platformReady => 'platform_ready',
        ProtocolStatus.future => 'future',
      };
}

class CameraSetup {
  const CameraSetup({
    required this.views,
    required this.fullBodyRequired,
    required this.minDistanceM,
    required this.maxDistanceM,
    required this.minVisibilityLandmarks,
    this.framingNoteKey,
  });

  final List<String> views;
  final bool fullBodyRequired;
  final double minDistanceM;
  final double maxDistanceM;
  final List<String> minVisibilityLandmarks;
  final String? framingNoteKey;

  factory CameraSetup.fromJson(Map<String, dynamic> json) {
    final dist = json['est_distance_m'] as Map<String, dynamic>;
    return CameraSetup(
      views: (json['views'] as List).cast<String>(),
      fullBodyRequired: json['full_body_required'] as bool,
      minDistanceM: (dist['min'] as num).toDouble(),
      maxDistanceM: (dist['max'] as num).toDouble(),
      minVisibilityLandmarks:
          (json['min_visibility_landmarks'] as List?)?.cast<String>() ?? const [],
      framingNoteKey: json['framing_note_key'] as String?,
    );
  }
}

enum MovementTestKind {
  staticHold,
  sitToStand,
  walk,
  squat,
  stepDown,
  activeRom,
  passiveRom,
  reach,
  balance;

  static MovementTestKind fromWire(String v) => switch (v) {
        'static_hold' => MovementTestKind.staticHold,
        'sit_to_stand' => MovementTestKind.sitToStand,
        'walk' => MovementTestKind.walk,
        'squat' => MovementTestKind.squat,
        'step_down' => MovementTestKind.stepDown,
        'active_rom' => MovementTestKind.activeRom,
        'passive_rom' => MovementTestKind.passiveRom,
        'reach' => MovementTestKind.reach,
        'balance' => MovementTestKind.balance,
        _ => MovementTestKind.staticHold,
      };
}

class MovementTest {
  const MovementTest({
    required this.id,
    required this.nameKey,
    required this.instructionKey,
    required this.kind,
    required this.repeatCount,
    required this.required_,
    required this.derivedFeatures,
    this.durationS,
    this.cameraView,
  });

  final String id;
  final String nameKey;
  final String instructionKey;
  final MovementTestKind kind;
  final int repeatCount;

  /// `required` is a Dart keyword, so it is exposed as [required_]. It matters:
  /// an incomplete required test must degrade the result, not be silently
  /// skipped (PRD §32.1 protocol routing, §29 Reliability).
  final bool required_;
  final List<String> derivedFeatures;
  final double? durationS;
  final String? cameraView;

  factory MovementTest.fromJson(Map<String, dynamic> json) => MovementTest(
        id: json['id'] as String,
        nameKey: json['name_key'] as String,
        instructionKey: json['instruction_key'] as String,
        kind: MovementTestKind.fromWire(json['kind'] as String),
        repeatCount: json['repeat_count'] as int,
        required_: json['required'] as bool,
        derivedFeatures: (json['derived_features'] as List?)?.cast<String>() ?? const [],
        durationS: (json['duration_s'] as num?)?.toDouble(),
        cameraView: json['camera_view'] as String?,
      );
}

class JointChain {
  const JointChain({
    required this.name,
    required this.landmarks,
    required this.angleFeature,
  });

  final String name;
  final List<String> landmarks;
  final String angleFeature;

  factory JointChain.fromJson(Map<String, dynamic> json) => JointChain(
        name: json['name'] as String,
        landmarks: (json['landmarks'] as List).cast<String>(),
        angleFeature: json['angle_feature'] as String,
      );
}

class LandmarkSubset {
  const LandmarkSubset({required this.jointChains, required this.primaryAngle});

  final List<JointChain> jointChains;
  final String primaryAngle;

  factory LandmarkSubset.fromJson(Map<String, dynamic> json) => LandmarkSubset(
        jointChains: (json['joint_chains'] as List)
            .map((e) => JointChain.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        primaryAngle: json['primary_angle'] as String,
      );
}

/// Whether a wearable placement is backed by a trained model (PRD §14.3).
enum WearableConfigStatus {
  preferred,
  demonstrator,

  /// Wired into the app but no trained model consumes it. Must be surfaced
  /// honestly rather than presented as a working configuration.
  untrained;

  static WearableConfigStatus fromWire(String? v) => switch (v) {
        'preferred' => WearableConfigStatus.preferred,
        'demonstrator' => WearableConfigStatus.demonstrator,
        _ => WearableConfigStatus.untrained,
      };
}

class PodPlacement {
  const PodPlacement({
    required this.podIndex,
    required this.segment,
    required this.placementKey,
  });

  final int podIndex;
  final String segment;
  final String placementKey;

  factory PodPlacement.fromJson(Map<String, dynamic> json) => PodPlacement(
        podIndex: json['pod_index'] as int,
        segment: json['segment'] as String,
        placementKey: json['placement_key'] as String,
      );
}

class WearableConfiguration {
  const WearableConfiguration({
    required this.id,
    required this.pods,
    required this.labelKey,
    required this.status,
  });

  final String id;
  final List<PodPlacement> pods;
  final String labelKey;
  final WearableConfigStatus status;

  factory WearableConfiguration.fromJson(Map<String, dynamic> json) =>
      WearableConfiguration(
        id: json['id'] as String,
        pods: (json['pods'] as List)
            .map((e) => PodPlacement.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        labelKey: json['label_key'] as String,
        status: WearableConfigStatus.fromWire(json['status'] as String?),
      );
}

class WearableSpec {
  const WearableSpec({
    required this.supported,
    required this.configurations,
    required this.sensorChannels,
    required this.sampleRateHz,
  });

  final bool supported;
  final List<WearableConfiguration> configurations;
  final List<String> sensorChannels;
  final double sampleRateHz;

  WearableConfiguration? get preferred => configurations.firstWhereOrNull(
        (c) => c.status == WearableConfigStatus.preferred,
      );

  factory WearableSpec.fromJson(Map<String, dynamic> json) => WearableSpec(
        supported: json['supported'] as bool,
        configurations: (json['configurations'] as List)
            .map((e) => WearableConfiguration.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        sensorChannels: (json['sensor_channels'] as List).cast<String>(),
        sampleRateHz: (json['sample_rate_hz'] as num).toDouble(),
      );
}

enum FeatureGroup {
  cameraKinematics,
  cameraGait,
  cameraPosture,
  imuAcc,
  imuGyro,
  imuRelative,
  clinical;

  static FeatureGroup fromWire(String v) => switch (v) {
        'camera_kinematics' => FeatureGroup.cameraKinematics,
        'camera_gait' => FeatureGroup.cameraGait,
        'camera_posture' => FeatureGroup.cameraPosture,
        'imu_acc' => FeatureGroup.imuAcc,
        'imu_gyro' => FeatureGroup.imuGyro,
        'imu_relative' => FeatureGroup.imuRelative,
        _ => FeatureGroup.clinical,
      };
}

enum FeatureSource {
  camera,
  wearable,
  questionnaire,
  derived;

  static FeatureSource fromWire(String v) => switch (v) {
        'camera' => FeatureSource.camera,
        'wearable' => FeatureSource.wearable,
        'questionnaire' => FeatureSource.questionnaire,
        _ => FeatureSource.derived,
      };
}

class FeatureSpec {
  const FeatureSpec({
    required this.key,
    required this.group,
    required this.unit,
    required this.source,
    required this.description,
    required this.researchGrade,
  });

  final String key;
  final FeatureGroup group;
  final String unit;
  final FeatureSource source;
  final String description;

  /// PRD §13.4 / §15.3 — exploratory signals (varus/valgus proxies, crepitus
  /// variance) are computed and displayed for research but excluded from the
  /// primary model.
  final bool researchGrade;

  factory FeatureSpec.fromJson(Map<String, dynamic> json) => FeatureSpec(
        key: json['key'] as String,
        group: FeatureGroup.fromWire(json['group'] as String),
        unit: json['unit'] as String,
        source: FeatureSource.fromWire(json['source'] as String),
        description: json['description'] as String,
        researchGrade: json['research_grade'] as bool? ?? false,
      );
}

enum ModelBranch {
  cameraTemporal,
  imuTemporal,
  clinicalTabular,
  imaging,
  fusion,
  stage1Localisation;

  static ModelBranch fromWire(String v) => switch (v) {
        'camera_temporal' => ModelBranch.cameraTemporal,
        'imu_temporal' => ModelBranch.imuTemporal,
        'clinical_tabular' => ModelBranch.clinicalTabular,
        'imaging' => ModelBranch.imaging,
        'fusion' => ModelBranch.fusion,
        _ => ModelBranch.stage1Localisation,
      };

  String get wire => switch (this) {
        ModelBranch.cameraTemporal => 'camera_temporal',
        ModelBranch.imuTemporal => 'imu_temporal',
        ModelBranch.clinicalTabular => 'clinical_tabular',
        ModelBranch.imaging => 'imaging',
        ModelBranch.fusion => 'fusion',
        ModelBranch.stage1Localisation => 'stage1_localisation',
      };

  String get displayName => switch (this) {
        ModelBranch.cameraTemporal => 'Camera movement',
        ModelBranch.imuTemporal => 'Wearable sensor',
        ModelBranch.clinicalTabular => 'Questionnaire and history',
        ModelBranch.imaging => 'Medical imaging',
        ModelBranch.fusion => 'Combined result',
        ModelBranch.stage1Localisation => 'Whole-body screen',
      };
}

/// PRD §26.5 — the single source of truth for what a claim is allowed to be.
enum TrainingStatus {
  trained,
  untrainedInsufficientData,
  prototypeRuleBased,
  planned;

  static TrainingStatus fromWire(String? v) => switch (v) {
        'trained' => TrainingStatus.trained,
        'untrained_insufficient_data' => TrainingStatus.untrainedInsufficientData,
        'prototype_rule_based' => TrainingStatus.prototypeRuleBased,
        _ => TrainingStatus.planned,
      };

  /// Whether this branch may contribute a score to fusion at all.
  bool get canScore =>
      this == TrainingStatus.trained || this == TrainingStatus.prototypeRuleBased;

  String get wire => switch (this) {
        TrainingStatus.trained => 'trained',
        TrainingStatus.untrainedInsufficientData => 'untrained_insufficient_data',
        TrainingStatus.prototypeRuleBased => 'prototype_rule_based',
        TrainingStatus.planned => 'planned',
      };

  /// Deliberately blunt: "trained" is never "clinically validated".
  String get honestyLabel => switch (this) {
        TrainingStatus.trained => 'Prototype model — trained on a research dataset, not clinically validated',
        TrainingStatus.untrainedInsufficientData => 'Not trained — insufficient labelled data',
        TrainingStatus.prototypeRuleBased => 'Prototype rule-based scoring, not a trained model',
        TrainingStatus.planned => 'Planned — no model implemented yet',
      };
}

class ModelTarget {
  const ModelTarget({
    required this.label,
    required this.labelSource,
    required this.labelProvenance,
  });

  final String label;
  final String labelSource;
  final String labelProvenance;

  factory ModelTarget.fromJson(Map<String, dynamic> json) => ModelTarget(
        label: json['label'] as String,
        labelSource: json['label_source'] as String,
        labelProvenance: json['label_provenance'] as String,
      );
}

class ModelSpec {
  const ModelSpec({
    required this.branch,
    required this.modelId,
    required this.version,
    required this.target,
    required this.deployment,
    required this.trainingStatus,
    required this.explainability,
    required this.inputModalities,
    required this.limitations,
    this.architecture,
    this.dataset,
    this.placementNote,
    this.metrics,
  });

  final ModelBranch branch;
  final String modelId;
  final String version;
  final ModelTarget target;
  final List<String> deployment;
  final TrainingStatus trainingStatus;
  final String explainability;
  final List<String> inputModalities;
  final List<String> limitations;
  final String? architecture;
  final String? dataset;

  /// Set when training data used a different sensor placement from the protocol
  /// (PRD §33 "Wearable placement variation"). Rendered so a score is never
  /// read as if it came from the intended placement.
  final String? placementNote;
  final Map<String, dynamic>? metrics;

  factory ModelSpec.fromJson(Map<String, dynamic> json) => ModelSpec(
        branch: ModelBranch.fromWire(json['branch'] as String),
        modelId: json['model_id'] as String,
        version: json['version'] as String,
        target: ModelTarget.fromJson(json['target'] as Map<String, dynamic>),
        deployment: (json['deployment'] as List).cast<String>(),
        trainingStatus: TrainingStatus.fromWire(json['training_status'] as String?),
        explainability: json['explainability'] as String? ?? 'none',
        inputModalities: (json['input_modalities'] as List?)?.cast<String>() ?? const [],
        limitations: (json['limitations'] as List?)?.cast<String>() ?? const [],
        architecture: json['architecture'] as String?,
        dataset: json['dataset'] as String?,
        placementNote: json['placement_note'] as String?,
        metrics: json['metrics'] as Map<String, dynamic>?,
      );
}

class RiskBand {
  const RiskBand({
    required this.id,
    required this.minScore,
    required this.labelKey,
    required this.actionKey,
  });

  final String id;
  final double minScore;
  final String labelKey;
  final String actionKey;

  factory RiskBand.fromJson(Map<String, dynamic> json) => RiskBand(
        id: json['id'] as String,
        minScore: (json['min_score'] as num).toDouble(),
        labelKey: json['label_key'] as String,
        actionKey: json['action_key'] as String,
      );
}

class RiskLogic {
  const RiskLogic({
    required this.bands,
    required this.defaultReferral,
    required this.thresholdProvenance,
    required this.deferralAllowed,
    required this.deferralReasonRequired,
    this.operatingPoint,
  });

  final List<RiskBand> bands;
  final String defaultReferral;
  final String thresholdProvenance;
  final bool deferralAllowed;
  final bool deferralReasonRequired;
  final Map<String, dynamic>? operatingPoint;

  /// True when the thresholds are documented as placeholders. The result screen
  /// and the report must say so rather than implying a validated cut-off.
  bool get isPlaceholder =>
      thresholdProvenance.toUpperCase().contains('PLACEHOLDER');

  /// Highest band whose floor the score clears. Bands are validated as ordered
  /// and starting at 0.0 by tools/lint_protocols.py, so a linear scan is safe.
  RiskBand bandFor(double score) {
    var chosen = bands.first;
    for (final band in bands) {
      if (score >= band.minScore) chosen = band;
    }
    return chosen;
  }

  factory RiskLogic.fromJson(Map<String, dynamic> json) {
    final deferral = json['deferral'] as Map<String, dynamic>?;
    return RiskLogic(
      bands: (json['bands'] as List)
          .map((e) => RiskBand.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      defaultReferral: json['default_referral'] as String,
      thresholdProvenance: json['threshold_provenance'] as String? ?? '',
      deferralAllowed: deferral?['allowed'] as bool? ?? false,
      deferralReasonRequired: deferral?['reason_required'] as bool? ?? true,
      operatingPoint: json['operating_point'] as Map<String, dynamic>?,
    );
  }
}

class ReportSectionSpec {
  const ReportSectionSpec({
    required this.sectionId,
    required this.titleKey,
    required this.fields,
  });

  final String sectionId;
  final String titleKey;
  final List<String> fields;

  factory ReportSectionSpec.fromJson(Map<String, dynamic> json) =>
      ReportSectionSpec(
        sectionId: json['section_id'] as String,
        titleKey: json['title_key'] as String,
        fields: (json['fields'] as List).cast<String>(),
      );
}

class SafetySpec {
  const SafetySpec({
    required this.contraindications,
    required this.redFlags,
    required this.stopConditions,
    required this.disclaimerKey,
  });

  final List<String> contraindications;

  /// Findings that bypass the model and route straight to clinical review
  /// (PRD §29 "Clinical safety").
  final List<String> redFlags;
  final List<String> stopConditions;
  final String disclaimerKey;

  factory SafetySpec.fromJson(Map<String, dynamic> json) => SafetySpec(
        contraindications: (json['contraindications'] as List?)?.cast<String>() ?? const [],
        redFlags: (json['red_flags'] as List?)?.cast<String>() ?? const [],
        stopConditions: (json['stop_conditions'] as List?)?.cast<String>() ?? const [],
        disclaimerKey: json['disclaimer_key'] as String? ??
            'disclaimer.screening_not_diagnosis',
      );
}

// ────────────────────────────────────────────────────────────── the protocol ──

class JointProtocol {
  const JointProtocol({
    required this.jointId,
    required this.protocolVersion,
    required this.display,
    required this.status,
    required this.supportedSides,
    required this.questionnaire,
    required this.cameraSetup,
    required this.movementTests,
    required this.landmarks,
    required this.wearable,
    required this.featurePipeline,
    required this.models,
    required this.riskLogic,
    required this.reportTemplate,
    required this.safety,
  });

  final String jointId;
  final String protocolVersion;
  final ProtocolDisplay display;
  final ProtocolStatus status;
  final List<String> supportedSides;
  final ClinicalQuestionnaire questionnaire;
  final CameraSetup cameraSetup;
  final List<MovementTest> movementTests;
  final LandmarkSubset landmarks;
  final WearableSpec wearable;
  final List<FeatureSpec> featurePipeline;
  final List<ModelSpec> models;
  final RiskLogic riskLogic;
  final List<ReportSectionSpec> reportTemplate;
  final SafetySpec safety;

  List<MovementTest> get requiredTests =>
      movementTests.where((t) => t.required_).toList(growable: false);

  ModelSpec? modelFor(ModelBranch branch) =>
      models.firstWhereOrNull((m) => m.branch == branch);

  FeatureSpec? feature(String key) =>
      featurePipeline.firstWhereOrNull((f) => f.key == key);

  /// Features the primary model may consume — research-grade signals excluded
  /// (PRD §13.4, §15.3).
  List<FeatureSpec> get primaryFeatures =>
      featurePipeline.where((f) => !f.researchGrade).toList(growable: false);

  Map<String, dynamic> toJson() => {
        'joint_id': jointId,
        'protocol_version': protocolVersion,
      };

  factory JointProtocol.fromJson(Map<String, dynamic> json) => JointProtocol(
        jointId: json['joint_id'] as String,
        protocolVersion: json['protocol_version'] as String,
        display: ProtocolDisplay.fromJson(json['display'] as Map<String, dynamic>),
        status: ProtocolStatus.fromWire(json['status'] as String?),
        supportedSides: (json['supported_sides'] as List).cast<String>(),
        questionnaire: ClinicalQuestionnaire.fromJson(
          json['clinical_questionnaire'] as Map<String, dynamic>,
        ),
        cameraSetup: CameraSetup.fromJson(json['camera_setup'] as Map<String, dynamic>),
        movementTests: (json['movement_tests'] as List)
            .map((e) => MovementTest.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        landmarks: LandmarkSubset.fromJson(json['landmark_subset'] as Map<String, dynamic>),
        wearable: WearableSpec.fromJson(json['wearable'] as Map<String, dynamic>),
        featurePipeline: (json['feature_pipeline'] as List)
            .map((e) => FeatureSpec.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        models: (json['models'] as List)
            .map((e) => ModelSpec.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        riskLogic: RiskLogic.fromJson(json['risk_logic'] as Map<String, dynamic>),
        reportTemplate: (json['report_template'] as List)
            .map((e) => ReportSectionSpec.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        safety: SafetySpec.fromJson(json['safety'] as Map<String, dynamic>),
      );
}
