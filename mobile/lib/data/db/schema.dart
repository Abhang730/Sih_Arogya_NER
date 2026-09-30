// Local database schema (PRD §21.1, §21.2).
//
// The entities below are exactly the ones PRD §21.1 names, so the local store
// and the cloud tier do not drift into two different data models.
//
// One deliberate structural choice: every entity keeps a small set of INDEXED
// columns for the things the app actually queries (patient, joint, side,
// timestamps, sync status) and stores the rich nested result as a JSON payload
// column. The alternative — a column per feature — would mean a schema
// migration every time a protocol gains a feature, and protocols are meant to
// evolve by editing JSON (PRD §12.1, §29 "Maintainability"). The nested results
// are also the part that must be reproduced byte-for-byte in the report, so
// keeping their original shape is a correctness property, not a shortcut.
//
// raw video is NOT stored anywhere in this schema, by design (PRD §25.2).

class ArogyaSchema {
  const ArogyaSchema._();

  static const int version = 1;

  static const String workers = 'worker';
  static const String patients = 'patient';
  static const String screenings = 'screening';
  static const String stage1 = 'stage1_assessment';
  static const String jointAssessments = 'joint_assessment';
  static const String aiResults = 'ai_result';
  static const String reports = 'report';
  static const String attachments = 'attachment';
  static const String syncQueue = 'sync_queue';
  static const String auditEvents = 'audit_event';

  /// Tables that carry patient-identifiable data and must therefore live only in
  /// the encrypted store (PRD §25.1).
  static const Set<String> sensitiveTables = {
    patients,
    screenings,
    stage1,
    jointAssessments,
    aiResults,
    reports,
    attachments,
  };

  static const List<String> createStatements = [
    // ── Worker (PRD §7.1) ───────────────────────────────────────────────
    '''
    CREATE TABLE $workers (
      worker_id        TEXT PRIMARY KEY,
      display_name     TEXT NOT NULL,
      role             TEXT NOT NULL,
      phc              TEXT,
      district         TEXT,
      -- Only a salted digest of the passcode is stored. Even on a device, a
      -- recoverable passcode would let a stolen phone be used to sign in.
      passcode_hash    TEXT NOT NULL,
      passcode_salt    TEXT NOT NULL,
      credential_meta  TEXT,
      created_at       TEXT NOT NULL,
      last_login_at    TEXT,
      failed_attempts  INTEGER NOT NULL DEFAULT 0,
      revoked          INTEGER NOT NULL DEFAULT 0
    )
    ''',

    // ── Patient (PRD §7.2) ──────────────────────────────────────────────
    '''
    CREATE TABLE $patients (
      arogya_patient_id TEXT PRIMARY KEY,
      name              TEXT NOT NULL,
      age_years         INTEGER,
      sex               TEXT,
      height_cm         REAL,
      weight_kg         REAL,
      district          TEXT,
      -- Protected identity reference. Masked in every UI surface (FR-04).
      protected_identity       TEXT,
      protected_identity_token TEXT,
      consent_given      INTEGER NOT NULL DEFAULT 0,
      consent_at         TEXT,
      created_by         TEXT NOT NULL,
      created_at         TEXT NOT NULL,
      updated_at         TEXT NOT NULL,
      deleted_at         TEXT,
      sync_state         TEXT NOT NULL DEFAULT 'pending',
      remote_id          TEXT
    )
    ''',
    'CREATE INDEX idx_patient_name ON $patients(name)',
    'CREATE INDEX idx_patient_sync ON $patients(sync_state)',

    // ── Screening (PRD §21.1) ───────────────────────────────────────────
    '''
    CREATE TABLE $screenings (
      screening_id      TEXT PRIMARY KEY,
      arogya_patient_id TEXT NOT NULL,
      worker_id         TEXT NOT NULL,
      status            TEXT NOT NULL,
      protocol_registry_version TEXT,
      clinical_strings_version  TEXT,
      app_version       TEXT,
      started_at        TEXT NOT NULL,
      completed_at      TEXT,
      payload           TEXT,
      sync_state        TEXT NOT NULL DEFAULT 'pending',
      FOREIGN KEY (arogya_patient_id) REFERENCES $patients (arogya_patient_id)
    )
    ''',
    'CREATE INDEX idx_screening_patient ON $screenings(arogya_patient_id, started_at DESC)',
    'CREATE INDEX idx_screening_sync ON $screenings(sync_state)',

    // ── Stage 1 assessment (PRD §8, §9.5, §10.5) ────────────────────────
    '''
    CREATE TABLE $stage1 (
      screening_id      TEXT PRIMARY KEY,
      questionnaire     TEXT NOT NULL,
      pose_features     TEXT,
      gait_features     TEXT,
      posture_features  TEXT,
      joint_risk_map    TEXT,
      quality           TEXT,
      pose_engine_id    TEXT,
      pose_engine_synthetic INTEGER NOT NULL DEFAULT 0,
      recorded_at       TEXT NOT NULL,
      FOREIGN KEY (screening_id) REFERENCES $screenings (screening_id)
    )
    ''',

    // ── Joint assessment (PRD §13, §21.1) ───────────────────────────────
    '''
    CREATE TABLE $jointAssessments (
      assessment_id     TEXT PRIMARY KEY,
      screening_id      TEXT NOT NULL,
      joint_id          TEXT NOT NULL,
      side              TEXT NOT NULL,
      protocol_version  TEXT NOT NULL,
      questionnaire     TEXT,
      questionnaire_instrument TEXT,
      movement_features TEXT,
      sensor_features   TEXT,
      sensor_placement  TEXT,
      movement_series   TEXT,
      imaging_available INTEGER NOT NULL DEFAULT 0,
      recorded_at       TEXT NOT NULL,
      FOREIGN KEY (screening_id) REFERENCES $screenings (screening_id)
    )
    ''',
    'CREATE INDEX idx_joint_screening ON $jointAssessments(screening_id)',

    // ── AI result (PRD §18.4, §27.2) ────────────────────────────────────
    '''
    CREATE TABLE $aiResults (
      result_id         TEXT PRIMARY KEY,
      screening_id      TEXT NOT NULL,
      assessment_id     TEXT,
      tier              TEXT NOT NULL,
      stage1_payload    TEXT,
      fusion_payload    TEXT,
      branch_scores     TEXT,
      fused_score       REAL,
      risk_band         TEXT,
      referral_action   TEXT,
      model_versions    TEXT,
      config_provenance TEXT,
      caveats           TEXT,
      agreement         REAL,
      produced_at       TEXT NOT NULL,
      FOREIGN KEY (screening_id) REFERENCES $screenings (screening_id)
    )
    ''',
    'CREATE INDEX idx_airesult_screening ON $aiResults(screening_id)',

    // ── Report (PRD §24.1) ──────────────────────────────────────────────
    '''
    CREATE TABLE $reports (
      report_id         TEXT PRIMARY KEY,
      screening_id      TEXT NOT NULL,
      report_version    TEXT NOT NULL,
      generated_at      TEXT NOT NULL,
      pdf_path          TEXT,
      payload           TEXT,
      FOREIGN KEY (screening_id) REFERENCES $screenings (screening_id)
    )
    ''',

    // ── Attachment (PRD §16, §22.2) ─────────────────────────────────────
    '''
    CREATE TABLE $attachments (
      attachment_id     TEXT PRIMARY KEY,
      screening_id      TEXT NOT NULL,
      kind              TEXT NOT NULL,
      local_path        TEXT NOT NULL,
      mime_type         TEXT,
      byte_size         INTEGER,
      captured_at       TEXT NOT NULL,
      sync_state        TEXT NOT NULL DEFAULT 'pending',
      FOREIGN KEY (screening_id) REFERENCES $screenings (screening_id)
    )
    ''',

    // ── Sync queue (PRD §22.3, §28 FR-20) ───────────────────────────────
    '''
    CREATE TABLE $syncQueue (
      record_hash       TEXT PRIMARY KEY,
      entity            TEXT NOT NULL,
      record_id         TEXT NOT NULL,
      operation         TEXT NOT NULL,
      attempts          INTEGER NOT NULL DEFAULT 0,
      last_error        TEXT,
      last_attempt_at   TEXT,
      queued_at         TEXT NOT NULL,
      -- Sequence, not a timestamp: two records queued in the same millisecond
      -- must still sync in the order they were created.
      seq               INTEGER NOT NULL
    )
    ''',
    'CREATE INDEX idx_sync_queue_seq ON $syncQueue(seq)',

    // ── Audit event (PRD §25.1, §28 FR-24) ──────────────────────────────
    '''
    CREATE TABLE $auditEvents (
      event_id          TEXT PRIMARY KEY,
      actor             TEXT,
      action            TEXT NOT NULL,
      record_id         TEXT,
      entity            TEXT,
      device_meta       TEXT,
      occurred_at       TEXT NOT NULL
    )
    ''',
    'CREATE INDEX idx_audit_time ON $auditEvents(occurred_at DESC)',
  ];
}
