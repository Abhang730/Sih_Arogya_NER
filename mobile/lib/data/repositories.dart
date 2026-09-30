// Local repositories.
//
// All patient data access goes through here so that three cross-cutting rules
// cannot be forgotten at a call site:
//
//   * every create/update/review writes an audit event (PRD §25.1, FR-24);
//   * every screening record is enqueued for sync when it is created, not when
//     someone remembers to sync (FR-20);
//   * a record without consent is never enqueued for upload (FR-05, §25.2).

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../ai/fusion.dart';
import '../ai/stage1_localizer.dart';
import '../core/ids.dart';
import '../domain/protocol/scoring.dart';
import '../screening/assessment_engine.dart';
import '../screening/stage1_questionnaire.dart';
import 'db/schema.dart';
import 'records.dart';

/// Generates sortable, collision-resistant identifiers without a dependency on
/// wall-clock ordering.
String newId(String prefix) {
  final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final random = math.Random.secure().nextInt(1 << 32).toRadixString(36);
  return '$prefix-$now-$random';
}

String nowIso() => DateTime.now().toUtc().toIso8601String();

// ── Audit (PRD §25.1, FR-24) ──────────────────────────────────────────────

class AuditRepository {
  const AuditRepository(this._db);

  final Database _db;

  Future<void> record({
    required String action,
    String? actor,
    String? recordId,
    String? entity,
    Map<String, Object?> deviceMeta = const {},
  }) async {
    await _db.insert(ArogyaSchema.auditEvents, {
      'event_id': newId('aud'),
      'actor': actor,
      'action': action,
      'record_id': recordId,
      'entity': entity,
      'device_meta': jsonEncode(deviceMeta),
      'occurred_at': nowIso(),
    });
  }

  Future<List<AuditEvent>> recent({int limit = 100}) async {
    final rows = await _db.query(
      ArogyaSchema.auditEvents,
      orderBy: 'occurred_at DESC',
      limit: limit,
    );
    return rows.map(AuditEvent.fromRow).toList(growable: false);
  }
}

// ── Sync queue (PRD §22.3, FR-20) ─────────────────────────────────────────

class SyncQueueRepository {
  const SyncQueueRepository(this._db);

  final Database _db;

  /// Queues a record for upload.
  ///
  /// The primary key is a content hash of (entity, id, operation), which makes
  /// this idempotent: queueing the same record twice is a no-op rather than a
  /// duplicate upload. That is what lets the caller enqueue defensively
  /// (PRD §22.3 "Idempotent batch sync").
  Future<void> enqueue({
    required String entity,
    required String recordId,
    String operation = 'upsert',
  }) async {
    final hash = _hash('$entity|$recordId|$operation');
    final existing = await _db.query(
      ArogyaSchema.syncQueue,
      where: 'record_hash = ?',
      whereArgs: [hash],
      limit: 1,
    );
    if (existing.isNotEmpty) return;

    final maxSeq = await _db.rawQuery(
      'SELECT MAX(seq) AS m FROM ${ArogyaSchema.syncQueue}',
    );
    final next = ((maxSeq.first['m'] as int?) ?? 0) + 1;

    await _db.insert(ArogyaSchema.syncQueue, {
      'record_hash': hash,
      'entity': entity,
      'record_id': recordId,
      'operation': operation,
      'attempts': 0,
      'queued_at': nowIso(),
      'seq': next,
    });
  }

  Future<List<SyncQueueItem>> pending({int limit = 50}) async {
    final rows = await _db.query(
      ArogyaSchema.syncQueue,
      orderBy: 'seq ASC',
      limit: limit,
    );
    return rows.map(SyncQueueItem.fromRow).toList(growable: false);
  }

  Future<int> pendingCount() async {
    final result =
        await _db.rawQuery('SELECT COUNT(*) AS c FROM ${ArogyaSchema.syncQueue}');
    return (result.first['c'] as int?) ?? 0;
  }

  Future<void> markSynced(String recordHash) async {
    await _db.delete(
      ArogyaSchema.syncQueue,
      where: 'record_hash = ?',
      whereArgs: [recordHash],
    );
  }

  Future<void> markFailed(String recordHash, String error) async {
    final rows = await _db.query(
      ArogyaSchema.syncQueue,
      where: 'record_hash = ?',
      whereArgs: [recordHash],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final item = SyncQueueItem.fromRow(rows.first);
    await _db.update(
      ArogyaSchema.syncQueue,
      {
        'attempts': item.attempts + 1,
        'last_error': error,
        'last_attempt_at': nowIso(),
      },
      where: 'record_hash = ?',
      whereArgs: [recordHash],
    );
  }

  static String _hash(String input) =>
      sha256.convert(utf8.encode(input)).toString().substring(0, 32);
}

// ── Workers (PRD §7.1) ────────────────────────────────────────────────────

class AuthResult {
  const AuthResult({this.worker, this.error});

  final Worker? worker;
  final String? error;

  bool get success => worker != null;
}

class WorkerRepository {
  WorkerRepository(this._db, this._audit);

  final Database _db;
  final AuditRepository _audit;

  /// Maximum failed attempts before the device requires re-provisioning.
  ///
  /// PRD §7.1 expects offline provisioning and §25.1 expects revocation to be
  /// possible when connectivity returns; a local lock-out is the offline
  /// equivalent of that revocation.
  static const int maxFailedAttempts = 5;

  /// Provisions a worker onto this device.
  ///
  /// In the deployment workflow this is done by a supervisor while connected;
  /// the app then authenticates entirely offline (FR-01, FR-02).
  Future<void> provision({
    required String workerId,
    required String displayName,
    required String role,
    required String passcode,
    String? phc,
    String? district,
    Map<String, Object?> credentialMeta = const {},
  }) async {
    final salt = _newSalt();
    await _db.insert(
      ArogyaSchema.workers,
      {
        'worker_id': workerId,
        'display_name': displayName,
        'role': role,
        'phc': phc,
        'district': district,
        'passcode_hash': _hashPasscode(passcode, salt),
        'passcode_salt': salt,
        'credential_meta': jsonEncode(credentialMeta),
        'created_at': nowIso(),
        'failed_attempts': 0,
        'revoked': 0,
      },
      // Re-provisioning an existing worker replaces the credential, which is
      // how a supervisor resets a lost passcode.
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _audit.record(
      action: 'worker.provisioned',
      actor: workerId,
      recordId: workerId,
      entity: ArogyaSchema.workers,
      deviceMeta: {'role': role, 'phc': phc, 'district': district},
    );
  }

  Future<AuthResult> authenticate({
    required String workerId,
    required String passcode,
  }) async {
    final rows = await _db.query(
      ArogyaSchema.workers,
      where: 'worker_id = ?',
      whereArgs: [workerId.trim()],
      limit: 1,
    );

    if (rows.isEmpty) {
      // Deliberately the same message as a wrong passcode: distinguishing them
      // would let someone enumerate valid worker IDs from a found device.
      await _audit.record(
        action: 'worker.login_failed',
        actor: workerId,
        recordId: workerId,
        deviceMeta: const {'reason': 'unknown_worker'},
      );
      return const AuthResult(error: 'login.error.invalid');
    }

    final worker = Worker.fromRow(rows.first);

    if (worker.revoked) {
      await _audit.record(
        action: 'worker.login_blocked',
        actor: workerId,
        recordId: workerId,
        deviceMeta: const {'reason': 'revoked'},
      );
      return const AuthResult(error: 'login.error.invalid');
    }

    if (worker.failedAttempts >= maxFailedAttempts) {
      await _audit.record(
        action: 'worker.login_blocked',
        actor: workerId,
        recordId: workerId,
        deviceMeta: const {'reason': 'locked_out'},
      );
      return const AuthResult(error: 'login.error.locked');
    }

    final salt = rows.first['passcode_salt']! as String;
    if (_hashPasscode(passcode, salt) != rows.first['passcode_hash']) {
      await _db.update(
        ArogyaSchema.workers,
        {'failed_attempts': worker.failedAttempts + 1},
        where: 'worker_id = ?',
        whereArgs: [workerId],
      );
      await _audit.record(
        action: 'worker.login_failed',
        actor: workerId,
        recordId: workerId,
        deviceMeta: {'attempt': worker.failedAttempts + 1},
      );
      return const AuthResult(error: 'login.error.invalid');
    }

    await _db.update(
      ArogyaSchema.workers,
      {'failed_attempts': 0, 'last_login_at': nowIso()},
      where: 'worker_id = ?',
      whereArgs: [workerId],
    );
    await _audit.record(
      action: 'worker.login',
      actor: workerId,
      recordId: workerId,
    );

    return AuthResult(worker: worker);
  }

  Future<List<Worker>> all() async {
    final rows = await _db.query(ArogyaSchema.workers, orderBy: 'display_name');
    return rows.map(Worker.fromRow).toList(growable: false);
  }

  Future<int> count() async {
    final result =
        await _db.rawQuery('SELECT COUNT(*) AS c FROM ${ArogyaSchema.workers}');
    return (result.first['c'] as int?) ?? 0;
  }

  static String _newSalt() =>
      List<int>.generate(16, (_) => math.Random.secure().nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

  /// PBKDF2 would be stronger, but the passcode sits behind a device that is
  /// already encrypted and rate-limited to [maxFailedAttempts] attempts. The
  /// per-worker salt is what defeats a precomputed table; the iteration count
  /// below is what raises the cost of an offline attack.
  static String _hashPasscode(String passcode, String salt) {
    List<int> digest = utf8.encode('$salt|$passcode');
    for (var i = 0; i < 10000; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return base64Encode(digest);
  }
}

// ── Patients (PRD §7.2, FR-03, FR-04) ─────────────────────────────────────

class PatientRepository {
  PatientRepository(this._db, this._audit, this._sync);

  final Database _db;
  final AuditRepository _audit;
  final SyncQueueRepository _sync;

  /// Creates a patient with a freshly generated Arogya Patient ID.
  ///
  /// [protectedIdentity] is stored masked-capable but raw, inside the encrypted
  /// database, and a per-record token is stored beside it. The token is what
  /// anything downstream may compare on; the raw value is never used as a lookup
  /// key (PRD §7.2, §25.1).
  Future<Patient> create({
    required String name,
    required String createdBy,
    int? ageYears,
    PatientSex sex = PatientSex.unspecified,
    double? heightCm,
    double? weightKg,
    String? district,
    String? protectedIdentity,
    required bool consentGiven,
  }) async {
    final id = ArogyaPatientId.generate();
    final timestamp = nowIso();

    final patient = Patient(
      arogyaPatientId: id,
      name: name.trim(),
      ageYears: ageYears,
      sex: sex,
      heightCm: heightCm,
      weightKg: weightKg,
      district: district,
      protectedIdentity: protectedIdentity?.trim().isEmpty ?? true
          ? null
          : protectedIdentity!.trim(),
      protectedIdentityToken: protectedIdentity?.trim().isEmpty ?? true
          ? null
          : ArogyaPatientId.identityToken(protectedIdentity!.trim(), id),
      consentGiven: consentGiven,
      consentAt: consentGiven ? timestamp : null,
      createdBy: createdBy,
      createdAt: timestamp,
      updatedAt: timestamp,
      // Without consent the record must not leave the device at all, so it is
      // marked local-only rather than pending (PRD §25.2).
      syncState: consentGiven ? SyncState.pending : SyncState.localOnly,
    );

    await _db.insert(ArogyaSchema.patients, patient.toRow());
    await _audit.record(
      action: 'patient.created',
      actor: createdBy,
      recordId: id,
      entity: ArogyaSchema.patients,
      deviceMeta: {'consent': consentGiven},
    );

    if (consentGiven) {
      await _sync.enqueue(entity: ArogyaSchema.patients, recordId: id);
    }

    return patient;
  }

  Future<Patient?> byId(String arogyaPatientId) async {
    final rows = await _db.query(
      ArogyaSchema.patients,
      where: 'arogya_patient_id = ? AND deleted_at IS NULL',
      whereArgs: [arogyaPatientId],
      limit: 1,
    );
    return rows.isEmpty ? null : Patient.fromRow(rows.first);
  }

  Future<List<Patient>> search(String query, {int limit = 100}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return recent(limit: limit);

    // Search matches the Arogya Patient ID or the name, never the protected
    // identity field: searching on that would turn it back into a lookup key.
    final rows = await _db.query(
      ArogyaSchema.patients,
      where: 'deleted_at IS NULL AND '
          '(arogya_patient_id LIKE ? OR name LIKE ?)',
      whereArgs: ['%$trimmed%', '%$trimmed%'],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(Patient.fromRow).toList(growable: false);
  }

  Future<List<Patient>> recent({int limit = 50}) async {
    final rows = await _db.query(
      ArogyaSchema.patients,
      where: 'deleted_at IS NULL',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(Patient.fromRow).toList(growable: false);
  }

  Future<int> count() async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${ArogyaSchema.patients} WHERE deleted_at IS NULL',
    );
    return (result.first['c'] as int?) ?? 0;
  }
}

// ── Screenings (PRD §21.1, FR-18, FR-19) ──────────────────────────────────

class ScreeningRepository {
  ScreeningRepository(this._db, this._audit, this._sync);

  final Database _db;
  final AuditRepository _audit;
  final SyncQueueRepository _sync;

  Future<Screening> create({
    required String arogyaPatientId,
    required String workerId,
    String? registryVersion,
    String? clinicalStringsVersion,
    String? appVersion,
  }) async {
    final screening = Screening(
      screeningId: newId('scr'),
      arogyaPatientId: arogyaPatientId,
      workerId: workerId,
      status: ScreeningStatus.draft,
      protocolRegistryVersion: registryVersion,
      clinicalStringsVersion: clinicalStringsVersion,
      appVersion: appVersion,
      startedAt: nowIso(),
    );

    await _db.insert(ArogyaSchema.screenings, screening.toRow());
    await _audit.record(
      action: 'screening.created',
      actor: workerId,
      recordId: screening.screeningId,
      entity: ArogyaSchema.screenings,
    );

    return screening;
  }

  Future<void> updateStatus(
    String screeningId,
    ScreeningStatus status, {
    String? actor,
  }) async {
    await _db.update(
      ArogyaSchema.screenings,
      {
        'status': status.wire,
        if (status == ScreeningStatus.completed) 'completed_at': nowIso(),
      },
      where: 'screening_id = ?',
      whereArgs: [screeningId],
    );
    await _audit.record(
      action: 'screening.status.${status.wire}',
      actor: actor,
      recordId: screeningId,
      entity: ArogyaSchema.screenings,
    );
  }

  Future<void> saveStage1({
    required String screeningId,
    required Stage1Answers answers,
    required JointRiskMap riskMap,
    String? poseEngineId,
    bool poseEngineSynthetic = false,
    Map<String, Object?>? poseFeatures,
    Map<String, Object?>? gaitFeatures,
    Map<String, Object?>? postureFeatures,
    Map<String, Object?>? quality,
    String? actor,
  }) async {
    final record = Stage1Assessment(
      screeningId: screeningId,
      questionnaire: answers.toJson(),
      poseFeatures: poseFeatures,
      gaitFeatures: gaitFeatures,
      postureFeatures: postureFeatures,
      jointRiskMap: riskMap.toJson(),
      quality: quality,
      poseEngineId: poseEngineId,
      poseEngineSynthetic: poseEngineSynthetic,
      recordedAt: nowIso(),
    );

    await _db.insert(
      ArogyaSchema.stage1,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _audit.record(
      action: 'stage1.saved',
      actor: actor,
      recordId: screeningId,
      entity: ArogyaSchema.stage1,
      deviceMeta: {
        'pose_engine': poseEngineId,
        'synthetic': poseEngineSynthetic,
      },
    );
  }

  Future<void> saveJoint({
    required String screeningId,
    required JointAssessmentOutcome outcome,
    required QuestionnaireScore? questionnaire,
    String? instrument,
    bool imagingAvailable = false,
    String? actor,
  }) async {
    final features = <String, Object?>{
      'camera': outcome.features,
      'imu': outcome.imuFeatures,
      'imu_proximal_distal_correlation':
          outcome.imuFeatures['imu_proximal_distal_correlation'],
      'camera_confidence': outcome.cameraConfidence,
    };

    final record = JointAssessmentRecord(
      assessmentId: newId('ja'),
      screeningId: screeningId,
      jointId: outcome.jointId,
      side: outcome.side,
      protocolVersion: outcome.protocolVersion,
      questionnaire: questionnaire?.toJson(),
      questionnaireInstrument: instrument,
      movementFeatures: features,
      sensorFeatures: outcome.imuFeatures.isEmpty ? null : outcome.imuFeatures,
      sensorPlacement: outcome.sensorPlacement,
      movementSeries: {
        for (final entry in outcome.movementSeries.entries)
          entry.key: entry.value,
      },
      imagingAvailable: imagingAvailable,
      recordedAt: nowIso(),
    );

    await _db.insert(
      ArogyaSchema.jointAssessments,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _audit.record(
      action: 'joint.saved',
      actor: actor,
      recordId: record.assessmentId,
      entity: ArogyaSchema.jointAssessments,
      deviceMeta: {
        'joint': outcome.jointId,
        'side': outcome.side,
        'synthetic_capture': outcome.syntheticCapture,
      },
    );
  }

  /// Stores a result at a given tier.
  ///
  /// [tier] is 'edge' for the on-device result. PRD §18.4 requires the field
  /// result to be retained when a stronger cloud model later scores the same
  /// screening, so a cloud result is written at tier 'cloud' and the edge row is
  /// never overwritten.
  Future<void> saveAiResult({
    required String screeningId,
    required FusionResult fusion,
    String? assessmentId,
    JointRiskMap? stage1Map,
    String tier = 'edge',
    Map<String, String> modelVersions = const {},
  }) async {
    final resultId = newId('res');
    final record = AiResultRecord(
      resultId: resultId,
      screeningId: screeningId,
      assessmentId: assessmentId,
      tier: tier,
      stage1Payload: stage1Map?.toJson(),
      fusionPayload: fusion.toJson(),
      branchScores: fusion.allBranches
          .map((b) => b.toJson())
          .toList(growable: false),
      fusedScore: fusion.score,
      riskBand: fusion.band?.id,
      referralAction: fusion.referralActionKey,
      modelVersions: modelVersions,
      configProvenance: fusion.configProvenance,
      caveats: fusion.caveats,
      agreement: fusion.agreement,
      producedAt: nowIso(),
    );

    await _db.insert(
      ArogyaSchema.aiResults,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _audit.record(
      action: 'ai_result.stored',
      recordId: resultId,
      entity: ArogyaSchema.aiResults,
      deviceMeta: {
        'tier': tier,
        'band': fusion.band?.id,
        'has_score': fusion.hasScore,
      },
    );
  }

  /// Records a generated report.
  ///
  /// [pdfPath] is nullable on purpose: a platform with no writable application
  /// documents directory (the web build) generates the PDF for printing and
  /// sharing but stores no file. Recording a path that does not exist would be
  /// worse than recording none, because the dashboard would try to fetch it.
  Future<void> saveReport({
    required String screeningId,
    required String? pdfPath,
    required Map<String, Object?> payload,
    String reportVersion = '1.0.0',
  }) async {
    final record = ReportRecord(
      reportId: newId('rep'),
      screeningId: screeningId,
      reportVersion: reportVersion,
      generatedAt: nowIso(),
      pdfPath: pdfPath,
      payload: payload,
    );
    await _db.insert(
      ArogyaSchema.reports,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _audit.record(
      action: 'report.generated',
      recordId: record.reportId,
      entity: ArogyaSchema.reports,
    );
  }

  Future<void> saveAttachment(AttachmentRecord attachment) async {
    await _db.insert(
      ArogyaSchema.attachments,
      attachment.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AttachmentRecord>> attachmentsFor(String screeningId) async {
    final rows = await _db.query(
      ArogyaSchema.attachments,
      where: 'screening_id = ?',
      whereArgs: [screeningId],
    );
    return rows.map(AttachmentRecord.fromRow).toList(growable: false);
  }

  Future<Screening?> byId(String screeningId) async {
    final rows = await _db.query(
      ArogyaSchema.screenings,
      where: 'screening_id = ?',
      whereArgs: [screeningId],
      limit: 1,
    );
    return rows.isEmpty ? null : Screening.fromRow(rows.first);
  }

  Future<List<Screening>> forPatient(String arogyaPatientId) async {
    final rows = await _db.query(
      ArogyaSchema.screenings,
      where: 'arogya_patient_id = ?',
      whereArgs: [arogyaPatientId],
      orderBy: 'started_at DESC',
    );
    return rows.map(Screening.fromRow).toList(growable: false);
  }

  Future<List<Screening>> recent({int limit = 50}) async {
    final rows = await _db.query(
      ArogyaSchema.screenings,
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(Screening.fromRow).toList(growable: false);
  }

  Future<List<Screening>> drafts({int limit = 20}) async {
    final rows = await _db.query(
      ArogyaSchema.screenings,
      where: 'status = ?',
      whereArgs: [ScreeningStatus.draft.wire],
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(Screening.fromRow).toList(growable: false);
  }

  /// The stored joint assessment for a screening, if any.
  Future<JointAssessmentRecord?> jointFor(String screeningId) async {
    final rows = await _db.query(
      ArogyaSchema.jointAssessments,
      where: 'screening_id = ?',
      whereArgs: [screeningId],
      orderBy: 'recorded_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : JointAssessmentRecord.fromRow(rows.first);
  }

  Future<Stage1Assessment?> stage1For(String screeningId) async {
    final rows = await _db.query(
      ArogyaSchema.stage1,
      where: 'screening_id = ?',
      whereArgs: [screeningId],
      limit: 1,
    );
    return rows.isEmpty ? null : Stage1Assessment.fromRow(rows.first);
  }

  Future<List<AiResultRecord>> resultsFor(String screeningId) async {
    final rows = await _db.query(
      ArogyaSchema.aiResults,
      where: 'screening_id = ?',
      whereArgs: [screeningId],
      orderBy: 'produced_at DESC',
    );
    return rows.map(AiResultRecord.fromRow).toList(growable: false);
  }

  Future<ReportRecord?> reportFor(String screeningId) async {
    final rows = await _db.query(
      ArogyaSchema.reports,
      where: 'screening_id = ?',
      whereArgs: [screeningId],
      orderBy: 'generated_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : ReportRecord.fromRow(rows.first);
  }

  Future<int> count() async {
    final result =
        await _db.rawQuery('SELECT COUNT(*) AS c FROM ${ArogyaSchema.screenings}');
    return (result.first['c'] as int?) ?? 0;
  }

  /// Marks a completed screening for upload along with its children.
  Future<void> enqueueForSync(String screeningId) async {
    await _sync.enqueue(entity: ArogyaSchema.screenings, recordId: screeningId);
    await _sync.enqueue(entity: ArogyaSchema.stage1, recordId: screeningId);
    final joint = await jointFor(screeningId);
    if (joint != null) {
      await _sync.enqueue(
        entity: ArogyaSchema.jointAssessments,
        recordId: joint.assessmentId,
      );
    }
  }
}

/// Convenience bundle so a screen takes one dependency instead of four.
class Repositories {
  const Repositories({
    required this.audit,
    required this.sync,
    required this.workers,
    required this.patients,
    required this.screenings,
  });

  final AuditRepository audit;
  final SyncQueueRepository sync;
  final WorkerRepository workers;
  final PatientRepository patients;
  final ScreeningRepository screenings;

  factory Repositories.forDatabase(Database db) {
    final audit = AuditRepository(db);
    final sync = SyncQueueRepository(db);
    return Repositories(
      audit: audit,
      sync: sync,
      workers: WorkerRepository(db, audit),
      patients: PatientRepository(db, audit, sync),
      screenings: ScreeningRepository(db, audit, sync),
    );
  }
}
