// Local records, mirroring the PRD §21.1 entities.
//
// These are deliberately plain data holders with explicit toRow/fromRow
// mappings. The mapping lives next to the record rather than inside a
// repository so that a column added to the schema cannot be forgotten in one of
// several call sites.

import 'dart:convert';

/// Sync lifecycle for a local record (PRD §28 FR-19, FR-20).
enum SyncState {
  pending('pending'),
  syncing('syncing'),
  synced('synced'),
  failed('failed'),

  /// The record is complete locally but must never be uploaded, e.g. because
  /// consent was not given for cloud storage.
  localOnly('local_only');

  const SyncState(this.wire);

  final String wire;

  static SyncState fromWire(String? value) => SyncState.values.firstWhere(
        (s) => s.wire == value,
        orElse: () => SyncState.pending,
      );
}

/// Screening progress (PRD §21.1).
enum ScreeningStatus {
  draft('draft'),
  questionnaireComplete('questionnaire_complete'),
  stage1Complete('stage1_complete'),
  jointComplete('joint_complete'),
  completed('completed'),
  abandoned('abandoned');

  const ScreeningStatus(this.wire);

  final String wire;

  static ScreeningStatus fromWire(String? value) => ScreeningStatus.values
      .firstWhere((s) => s.wire == value, orElse: () => ScreeningStatus.draft);
}

// ── Worker (PRD §7.1) ─────────────────────────────────────────────────────

class Worker {
  const Worker({
    required this.workerId,
    required this.displayName,
    required this.role,
    this.phc,
    this.district,
    this.credentialMeta,
    this.lastLoginAt,
    this.failedAttempts = 0,
    this.revoked = false,
  });

  final String workerId;
  final String displayName;
  final String role;
  final String? phc;
  final String? district;
  final String? credentialMeta;
  final String? lastLoginAt;
  final int failedAttempts;
  final bool revoked;

  /// Roles the app understands. An unknown role is treated as the lowest
  /// privilege rather than the highest (PRD §25.1 role-based authorization).
  bool get canCaptureScreenings => role == 'asha' || role == 'anm' || role == 'nurse' || role == 'doctor';

  bool get canViewAllPatients => role == 'doctor' || role == 'admin';

  Map<String, Object?> toRow() => {
        'worker_id': workerId,
        'display_name': displayName,
        'role': role,
        'phc': phc,
        'district': district,
        'credential_meta': credentialMeta,
        'last_login_at': lastLoginAt,
        'failed_attempts': failedAttempts,
        'revoked': revoked ? 1 : 0,
      };

  static Worker fromRow(Map<String, Object?> row) => Worker(
        workerId: row['worker_id']! as String,
        displayName: row['display_name']! as String,
        role: row['role']! as String,
        phc: row['phc'] as String?,
        district: row['district'] as String?,
        credentialMeta: row['credential_meta'] as String?,
        lastLoginAt: row['last_login_at'] as String?,
        failedAttempts: (row['failed_attempts'] as int?) ?? 0,
        revoked: (row['revoked'] as int?) == 1,
      );
}

// ── Patient (PRD §7.2) ────────────────────────────────────────────────────

enum PatientSex {
  female('female'),
  male('male'),
  other('other'),
  unspecified('unspecified');

  const PatientSex(this.wire);

  final String wire;

  static PatientSex fromWire(String? v) => PatientSex.values
      .firstWhere((s) => s.wire == v, orElse: () => PatientSex.unspecified);
}

class Patient {
  const Patient({
    required this.arogyaPatientId,
    required this.name,
    this.ageYears,
    this.sex = PatientSex.unspecified,
    this.heightCm,
    this.weightKg,
    this.district,
    this.protectedIdentity,
    this.protectedIdentityToken,
    this.consentGiven = false,
    this.consentAt,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.syncState = SyncState.pending,
    this.remoteId,
  });

  final String arogyaPatientId;
  final String name;
  final int? ageYears;
  final PatientSex sex;
  final double? heightCm;
  final double? weightKg;
  final String? district;

  /// The protected identity document reference. Never used for lookup and never
  /// shown in full (PRD §25.1, FR-04).
  final String? protectedIdentity;
  final String? protectedIdentityToken;

  final bool consentGiven;
  final String? consentAt;
  final String createdBy;
  final String createdAt;
  final String updatedAt;
  final SyncState syncState;
  final String? remoteId;

  Map<String, Object?> toRow() => {
        'arogya_patient_id': arogyaPatientId,
        'name': name,
        'age_years': ageYears,
        'sex': sex.wire,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'district': district,
        'protected_identity': protectedIdentity,
        'protected_identity_token': protectedIdentityToken,
        'consent_given': consentGiven ? 1 : 0,
        'consent_at': consentAt,
        'created_by': createdBy,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'sync_state': syncState.wire,
        'remote_id': remoteId,
      };

  static Patient fromRow(Map<String, Object?> row) => Patient(
        arogyaPatientId: row['arogya_patient_id']! as String,
        name: row['name']! as String,
        ageYears: row['age_years'] as int?,
        sex: PatientSex.fromWire(row['sex'] as String?),
        heightCm: (row['height_cm'] as num?)?.toDouble(),
        weightKg: (row['weight_kg'] as num?)?.toDouble(),
        district: row['district'] as String?,
        protectedIdentity: row['protected_identity'] as String?,
        protectedIdentityToken: row['protected_identity_token'] as String?,
        consentGiven: (row['consent_given'] as int?) == 1,
        consentAt: row['consent_at'] as String?,
        createdBy: row['created_by']! as String,
        createdAt: row['created_at']! as String,
        updatedAt: row['updated_at']! as String,
        syncState: SyncState.fromWire(row['sync_state'] as String?),
        remoteId: row['remote_id'] as String?,
      );
}

// ── Screening (PRD §21.1) ─────────────────────────────────────────────────

class Screening {
  const Screening({
    required this.screeningId,
    required this.arogyaPatientId,
    required this.workerId,
    required this.status,
    this.protocolRegistryVersion,
    this.clinicalStringsVersion,
    this.appVersion,
    required this.startedAt,
    this.completedAt,
    this.payload = const {},
    this.syncState = SyncState.pending,
  });

  final String screeningId;
  final String arogyaPatientId;
  final String workerId;
  final ScreeningStatus status;
  final String? protocolRegistryVersion;

  /// PRD §20.2: clinical string version travels with the record, so a score is
  /// always attributable to the exact instrument wording used.
  final String? clinicalStringsVersion;
  final String? appVersion;
  final String startedAt;
  final String? completedAt;
  final Map<String, Object?> payload;
  final SyncState syncState;

  Map<String, Object?> toRow() => {
        'screening_id': screeningId,
        'arogya_patient_id': arogyaPatientId,
        'worker_id': workerId,
        'status': status.wire,
        'protocol_registry_version': protocolRegistryVersion,
        'clinical_strings_version': clinicalStringsVersion,
        'app_version': appVersion,
        'started_at': startedAt,
        'completed_at': completedAt,
        'payload': jsonEncode(payload),
        'sync_state': syncState.wire,
      };

  static Screening fromRow(Map<String, Object?> row) => Screening(
        screeningId: row['screening_id']! as String,
        arogyaPatientId: row['arogya_patient_id']! as String,
        workerId: row['worker_id']! as String,
        status: ScreeningStatus.fromWire(row['status'] as String?),
        protocolRegistryVersion: row['protocol_registry_version'] as String?,
        clinicalStringsVersion: row['clinical_strings_version'] as String?,
        appVersion: row['app_version'] as String?,
        startedAt: row['started_at']! as String,
        completedAt: row['completed_at'] as String?,
        payload: _decodeMap(row['payload']),
        syncState: SyncState.fromWire(row['sync_state'] as String?),
      );
}

// ── Stage 1 assessment (PRD §8, §9.5) ─────────────────────────────────────

class Stage1Assessment {
  const Stage1Assessment({
    required this.screeningId,
    required this.questionnaire,
    this.poseFeatures,
    this.gaitFeatures,
    this.postureFeatures,
    this.jointRiskMap,
    this.quality,
    this.poseEngineId,
    this.poseEngineSynthetic = false,
    required this.recordedAt,
  });

  final String screeningId;

  /// Raw answers plus scored subscales.
  final Map<String, Object?> questionnaire;
  final Map<String, Object?>? poseFeatures;
  final Map<String, Object?>? gaitFeatures;
  final Map<String, Object?>? postureFeatures;

  /// The Stage-1 joint risk map payload (PRD §10.5).
  final Map<String, Object?>? jointRiskMap;
  final Map<String, Object?>? quality;

  /// Which pose engine produced this assessment, for traceability (PRD §27.2).
  final String? poseEngineId;

  /// True when the landmarks were generated, not measured. Stored so a
  /// synthetic assessment can never be mistaken for a real one later.
  final bool poseEngineSynthetic;

  final String recordedAt;

  Map<String, Object?> toRow() => {
        'screening_id': screeningId,
        'questionnaire': jsonEncode(questionnaire),
        'pose_features': _encodeMap(poseFeatures),
        'gait_features': _encodeMap(gaitFeatures),
        'posture_features': _encodeMap(postureFeatures),
        'joint_risk_map': _encodeMap(jointRiskMap),
        'quality': _encodeMap(quality),
        'pose_engine_id': poseEngineId,
        'pose_engine_synthetic': poseEngineSynthetic ? 1 : 0,
        'recorded_at': recordedAt,
      };

  static Stage1Assessment fromRow(Map<String, Object?> row) => Stage1Assessment(
        screeningId: row['screening_id']! as String,
        questionnaire: _decodeMap(row['questionnaire']),
        poseFeatures: _decodeNullableMap(row['pose_features']),
        gaitFeatures: _decodeNullableMap(row['gait_features']),
        postureFeatures: _decodeNullableMap(row['posture_features']),
        jointRiskMap: _decodeNullableMap(row['joint_risk_map']),
        quality: _decodeNullableMap(row['quality']),
        poseEngineId: row['pose_engine_id'] as String?,
        poseEngineSynthetic: (row['pose_engine_synthetic'] as int?) == 1,
        recordedAt: row['recorded_at']! as String,
      );
}

// ── Joint assessment (PRD §13, §37) ───────────────────────────────────────

class JointAssessmentRecord {
  const JointAssessmentRecord({
    required this.assessmentId,
    required this.screeningId,
    required this.jointId,
    required this.side,
    required this.protocolVersion,
    this.questionnaire,
    this.questionnaireInstrument,
    this.movementFeatures,
    this.sensorFeatures,
    this.sensorPlacement,
    this.movementSeries,
    this.imagingAvailable = false,
    required this.recordedAt,
  });

  final String assessmentId;
  final String screeningId;
  final String jointId;
  final String side;
  final String protocolVersion;
  final Map<String, Object?>? questionnaire;
  final String? questionnaireInstrument;
  final Map<String, Object?>? movementFeatures;
  final Map<String, Object?>? sensorFeatures;

  /// The placement the sensor data was actually captured at. Stored separately
  /// from the protocol's intended placement so DECISIONS.md D3's disclosure
  /// survives into the database and the dashboard.
  final String? sensorPlacement;

  /// Per-test angle and timing series for the dashboard movement view (PRD
  /// §23.1).
  final Map<String, Object?>? movementSeries;
  final bool imagingAvailable;
  final String recordedAt;

  Map<String, Object?> toRow() => {
        'assessment_id': assessmentId,
        'screening_id': screeningId,
        'joint_id': jointId,
        'side': side,
        'protocol_version': protocolVersion,
        'questionnaire': _encodeMap(questionnaire),
        'questionnaire_instrument': questionnaireInstrument,
        'movement_features': _encodeMap(movementFeatures),
        'sensor_features': _encodeMap(sensorFeatures),
        'sensor_placement': sensorPlacement,
        'movement_series': _encodeMap(movementSeries),
        'imaging_available': imagingAvailable ? 1 : 0,
        'recorded_at': recordedAt,
      };

  static JointAssessmentRecord fromRow(Map<String, Object?> row) =>
      JointAssessmentRecord(
        assessmentId: row['assessment_id']! as String,
        screeningId: row['screening_id']! as String,
        jointId: row['joint_id']! as String,
        side: row['side']! as String,
        protocolVersion: row['protocol_version']! as String,
        questionnaire: _decodeNullableMap(row['questionnaire']),
        questionnaireInstrument: row['questionnaire_instrument'] as String?,
        movementFeatures: _decodeNullableMap(row['movement_features']),
        sensorFeatures: _decodeNullableMap(row['sensor_features']),
        sensorPlacement: row['sensor_placement'] as String?,
        movementSeries: _decodeNullableMap(row['movement_series']),
        imagingAvailable: (row['imaging_available'] as int?) == 1,
        recordedAt: row['recorded_at']! as String,
      );
}

// ── AI result (PRD §18.4, §27.2) ──────────────────────────────────────────

class AiResultRecord {
  const AiResultRecord({
    required this.resultId,
    required this.screeningId,
    this.assessmentId,
    required this.tier,
    this.stage1Payload,
    this.fusionPayload,
    this.branchScores,
    this.fusedScore,
    this.riskBand,
    this.referralAction,
    this.modelVersions = const {},
    this.configProvenance,
    this.caveats = const [],
    this.agreement,
    required this.producedAt,
  });

  final String resultId;
  final String screeningId;
  final String? assessmentId;

  /// 'edge' or 'cloud'. PRD §18.4 requires the two to be retained SEPARATELY:
  /// a cloud enhancement must never overwrite the field result.
  final String tier;

  final Map<String, Object?>? stage1Payload;
  final Map<String, Object?>? fusionPayload;
  final List<Map<String, Object?>>? branchScores;
  final double? fusedScore;
  final String? riskBand;
  final String? referralAction;
  final Map<String, String> modelVersions;
  final String? configProvenance;
  final List<String> caveats;
  final double? agreement;
  final String producedAt;

  Map<String, Object?> toRow() => {
        'result_id': resultId,
        'screening_id': screeningId,
        'assessment_id': assessmentId,
        'tier': tier,
        'stage1_payload': _encodeMap(stage1Payload),
        'fusion_payload': _encodeMap(fusionPayload),
        'branch_scores': branchScores == null ? null : jsonEncode(branchScores),
        'fused_score': fusedScore,
        'risk_band': riskBand,
        'referral_action': referralAction,
        'model_versions': jsonEncode(modelVersions),
        'config_provenance': configProvenance,
        'caveats': jsonEncode(caveats),
        'agreement': agreement,
        'produced_at': producedAt,
      };

  static AiResultRecord fromRow(Map<String, Object?> row) => AiResultRecord(
        resultId: row['result_id']! as String,
        screeningId: row['screening_id']! as String,
        assessmentId: row['assessment_id'] as String?,
        tier: row['tier']! as String,
        stage1Payload: _decodeNullableMap(row['stage1_payload']),
        fusionPayload: _decodeNullableMap(row['fusion_payload']),
        branchScores: _decodeList(row['branch_scores']),
        fusedScore: (row['fused_score'] as num?)?.toDouble(),
        riskBand: row['risk_band'] as String?,
        referralAction: row['referral_action'] as String?,
        modelVersions: _decodeMap(row['model_versions'])
            .map((k, v) => MapEntry(k, v.toString())),
        configProvenance: row['config_provenance'] as String?,
        caveats: _decodeStringList(row['caveats']),
        agreement: (row['agreement'] as num?)?.toDouble(),
        producedAt: row['produced_at']! as String,
      );
}

// ── Report (PRD §24.1) ────────────────────────────────────────────────────

class ReportRecord {
  const ReportRecord({
    required this.reportId,
    required this.screeningId,
    required this.reportVersion,
    required this.generatedAt,
    this.pdfPath,
    this.payload = const {},
  });

  final String reportId;
  final String screeningId;
  final String reportVersion;
  final String generatedAt;
  final String? pdfPath;
  final Map<String, Object?> payload;

  Map<String, Object?> toRow() => {
        'report_id': reportId,
        'screening_id': screeningId,
        'report_version': reportVersion,
        'generated_at': generatedAt,
        'pdf_path': pdfPath,
        'payload': jsonEncode(payload),
      };

  static ReportRecord fromRow(Map<String, Object?> row) => ReportRecord(
        reportId: row['report_id']! as String,
        screeningId: row['screening_id']! as String,
        reportVersion: row['report_version']! as String,
        generatedAt: row['generated_at']! as String,
        pdfPath: row['pdf_path'] as String?,
        payload: _decodeMap(row['payload']),
      );
}

// ── Attachment (PRD §16) ──────────────────────────────────────────────────

class AttachmentRecord {
  const AttachmentRecord({
    required this.attachmentId,
    required this.screeningId,
    required this.kind,
    required this.localPath,
    this.mimeType,
    this.byteSize,
    required this.capturedAt,
    this.syncState = SyncState.pending,
  });

  final String attachmentId;
  final String screeningId;
  final String kind;
  final String localPath;
  final String? mimeType;
  final int? byteSize;
  final String capturedAt;
  final SyncState syncState;

  Map<String, Object?> toRow() => {
        'attachment_id': attachmentId,
        'screening_id': screeningId,
        'kind': kind,
        'local_path': localPath,
        'mime_type': mimeType,
        'byte_size': byteSize,
        'captured_at': capturedAt,
        'sync_state': syncState.wire,
      };

  static AttachmentRecord fromRow(Map<String, Object?> row) => AttachmentRecord(
        attachmentId: row['attachment_id']! as String,
        screeningId: row['screening_id']! as String,
        kind: row['kind']! as String,
        localPath: row['local_path']! as String,
        mimeType: row['mime_type'] as String?,
        byteSize: row['byte_size'] as int?,
        capturedAt: row['captured_at']! as String,
        syncState: SyncState.fromWire(row['sync_state'] as String?),
      );
}

// ── Sync queue (PRD §22.3, FR-20) ─────────────────────────────────────────

class SyncQueueItem {
  const SyncQueueItem({
    required this.recordHash,
    required this.entity,
    required this.recordId,
    required this.operation,
    this.attempts = 0,
    this.lastError,
    this.lastAttemptAt,
    required this.queuedAt,
    required this.seq,
  });

  final String recordHash;
  final String entity;
  final String recordId;
  final String operation;
  final int attempts;
  final String? lastError;
  final String? lastAttemptAt;
  final String queuedAt;
  final int seq;

  Map<String, Object?> toRow() => {
        'record_hash': recordHash,
        'entity': entity,
        'record_id': recordId,
        'operation': operation,
        'attempts': attempts,
        'last_error': lastError,
        'last_attempt_at': lastAttemptAt,
        'queued_at': queuedAt,
        'seq': seq,
      };

  static SyncQueueItem fromRow(Map<String, Object?> row) => SyncQueueItem(
        recordHash: row['record_hash']! as String,
        entity: row['entity']! as String,
        recordId: row['record_id']! as String,
        operation: row['operation']! as String,
        attempts: (row['attempts'] as int?) ?? 0,
        lastError: row['last_error'] as String?,
        lastAttemptAt: row['last_attempt_at'] as String?,
        queuedAt: row['queued_at']! as String,
        seq: (row['seq'] as int?) ?? 0,
      );
}

// ── Audit event (PRD §25.1, FR-24) ────────────────────────────────────────

class AuditEvent {
  const AuditEvent({
    required this.eventId,
    this.actor,
    required this.action,
    this.recordId,
    this.entity,
    this.deviceMeta = const {},
    required this.occurredAt,
  });

  final String eventId;
  final String? actor;
  final String action;
  final String? recordId;
  final String? entity;
  final Map<String, Object?> deviceMeta;
  final String occurredAt;

  Map<String, Object?> toRow() => {
        'event_id': eventId,
        'actor': actor,
        'action': action,
        'record_id': recordId,
        'entity': entity,
        'device_meta': jsonEncode(deviceMeta),
        'occurred_at': occurredAt,
      };

  static AuditEvent fromRow(Map<String, Object?> row) => AuditEvent(
        eventId: row['event_id']! as String,
        actor: row['actor'] as String?,
        action: row['action']! as String,
        recordId: row['record_id'] as String?,
        entity: row['entity'] as String?,
        deviceMeta: _decodeMap(row['device_meta']),
        occurredAt: row['occurred_at']! as String,
      );
}

// ── JSON column helpers ───────────────────────────────────────────────────

String? _encodeMap(Map<String, Object?>? map) =>
    map == null ? null : jsonEncode(map);

Map<String, Object?> _decodeMap(Object? raw) {
  if (raw is! String || raw.isEmpty) return const {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return const {};
  return decoded.cast<String, Object?>();
}

Map<String, Object?>? _decodeNullableMap(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return null;
  return decoded.cast<String, Object?>();
}

List<Map<String, Object?>>? _decodeList(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final decoded = jsonDecode(raw);
  if (decoded is! List) return null;
  return decoded
      .whereType<Map>()
      .map((e) => e.cast<String, Object?>())
      .toList(growable: false);
}

/// Decodes a plain list of strings, used for the caveat list.
///
/// Kept separate from [_decodeList] because the two store different shapes in
/// the same column type, and a single permissive decoder would silently turn a
/// malformed caveat list into an empty one — an empty caveat list reads as
/// "nothing to disclose", which is the wrong way to fail.
List<String> _decodeStringList(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return decoded.map((e) => e.toString()).toList(growable: false);
}
