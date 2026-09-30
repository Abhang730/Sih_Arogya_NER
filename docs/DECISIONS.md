# Decision Log

Every deviation from PRD §38's decision log is recorded here with its reason, so nothing about the
implementation is a silent surprise.

---

## D1 — Pose engine: ML Kit Pose Detection instead of MediaPipe BlazePose

**PRD §10.1 says:** "Primary candidate: MediaPipe BlazePose running on-device. The project also keeps
YOLOv8n-pose as a benchmark/alternative."

**What we did:** shipped `google_mlkit_pose_detection` behind a `PoseEngine` interface.

**Why:** there is no official MediaPipe Flutter plugin. The options were to hand-write a Kotlin
platform channel against MediaPipe Tasks, or to use the engine Google ships for exactly this job.
ML Kit Pose Detection is built on BlazePose, emits the identical 33-landmark topology (indices
verified against Google's Pose Landmarker documentation), and is actively maintained.

**Consequence:** ML Kit is Android/iOS only, so web and desktop builds have no real pose engine and
fall back to the synthetic generator, which labels its output as synthetic.

**Reversibility:** total. `MlKitPoseEngine` is the only file that imports ML Kit. A native MediaPipe
Tasks implementation or YOLOv8n-pose drops in behind the same `FramePoseEngine` interface without
touching the feature extractor or any screen.

---

## D2 — Real data instead of synthetic data, with explicit coverage gaps

**Decision:** train on real, publicly available labelled datasets rather than generated data.

**Datasets sourced:**

| Dataset | Real labels | Access | Used for |
|---|---|---|---|
| Clinical Gait Signals, Voisard et al. 2025 (*Scientific Data*) | 1356 gait trials, 260 participants, including **knee OA, hip OA** and ACL cohorts, each with clinical/radioclinical severity scores; 4 IMUs | Open (no account) | IMU branch, Stage-1 knee and hip localisation, clinical branch |
| Digital Knee X-ray / KL grading (Chen et al.) | Expert KL grades 0–4 | Kaggle account required | Optional imaging branch |
| Osteoarthritis Initiative (OAI) | WOMAC, KL grade, demographics for ~4800 participants | NIH NDA account, approval takes days | Ceiling for clinical-branch credibility |

**The honest limitation:** no public dataset anywhere pairs **monocular pose sequences with
joint-level OA labels**. Stage-1 camera localisation and the entire camera branch therefore stay
`untrained_insufficient_data`. Training them on anything less would mean publishing a camera-based OA
score with no evidence behind it.

**Ankle, shoulder, elbow and wrist** have no labelled OA cohort in any sourced dataset. Their models
are `untrained_insufficient_data` because of genuine dataset coverage gaps, not because the work is
pending.

---

## D3 — Sensor placement mismatch is disclosed, not hidden

**PRD §14.3** specifies a dual pod on **thigh + shin** for the knee.

**The only real labelled IMU data** uses **lumbar-L5 + dorsal foot**.

These are different measurements of different things. Rather than quietly training on one and
presenting it as the other, the protocols carry a `placement_note` and the trained model metadata
declares its actual `input_modalities`. The report and the specialist view render that notice beside
the score. See `protocols/knee/protocol.json` → `models[].placement_note`.

---

## D4 — Fusion weights are configurable and declared, never hard-coded

**PRD §15.5:** "The exact fusion behavior should be learned/calibrated from validation data rather
than fixed at arbitrary percentages."

**What we did:** fusion coefficients load from `assets/models/fusion_config.json`, written by the ml/
pipeline after fitting. Until that file exists, fusion runs on `FusionConfig.uncalibratedDefault` —
declared, reviewable weights with a stated rationale for each — and every result says so in its
caveats and in `configProvenance`.

A hard-coded weighted average would have violated the PRD directly. Refusing to produce any fused
score at all would block field use. Declared-and-labelled is the middle path, and the label is
impossible to drop because it travels inside `FusionResult`.

---

## D5 — Questionnaire items are not transcribed until clinically signed off

Each protocol's questionnaire carries a `status`:

- `specified` — item set and scoring implemented and verified against the published instrument. Only
  **WOMAC** (knee, hip) is in this state.
- `pending_clinical_sign_off` — the instrument is **named** (SPADI, FAAM, QuickDASH, PRWE) but its
  item set is not implemented, because transcribing or paraphrasing a licensed clinical instrument is
  a clinical-governance decision, not an engineering one.

A protocol in the pending state **cannot present questions to a worker**. `isUsable` is false and the
UI falls back to the Stage-1 symptom screen.

The schema enforces this with `if/then`: `items` and `scoring` are *required* when status is
`specified`, and the linter fails if items exist while status is pending.

---

## D6 — No invented severity cut-offs

**WOMAC scoring is implemented exactly as published:** 24 items × 0–4, pain 0–20 (5 items), stiffness
0–8 (2 items), function 0–68 (17 items), total 0–96, higher is worse, normalised as `raw / max × 100`.

`severity_bands` is **deliberately empty** in both the knee and hip protocols. There is no
universally accepted WOMAC severity cut-off, and inventing one would be an unvalidated clinical
claim. `tools/lint_protocols.py` re-derives the subscale maxima from the item list, so a
transcription slip fails the build instead of producing a quietly wrong score.

The measurement caveat carried into the product: the WOMAC **stiffness subscale has notably weaker
test-retest reliability** than pain and function. It is weighted lowest in the clinical branch for
that reason.

---

## D7 — Arogya Patient ID; no Aadhaar processing

**PRD §7.2** allows collecting Aadhaar "as requested by the product workflow"; **§1.2** warns it is a
sensitive identifier; **§7.2's** own privacy note says it must not become the visible longitudinal
identifier.

**Decision:** the app captures a **generic protected identity reference**, tokenises and masks it, and
uses the generated **Arogya Patient ID** everywhere. No Aadhaar-specific validation, storage or
processing is implemented. This avoids processing a sensitive identifier under the Aadhaar Act and
the DPDP Act 2023 for a workflow that does not need it.

---

## D8 — Protocol files are self-contained, with drift caught by tests

Shared instruments are **duplicated** into each joint protocol rather than referenced, so the mobile
loader stays trivial (one file per joint, no `$ref` resolution on a low-end device).

The cost of duplication is drift, so it is actively guarded:

- `tools/lint_protocols.py` fails if the same instrument name has different items or scoring in two
  protocols.
- `mobile/test/protocol/registry_test.dart` asserts the hip and knee WOMAC definitions are identical.

---

## D9 — Backend and dashboard stacks

- **Backend datastore: SQLite now, Postgres-ready** via SQLAlchemy 2.0 + Alembic, switched by one
  environment variable. Docker and PostgreSQL are not present on the build machine, and the PRD's
  §21.3 reference stack is PostgreSQL — so the code targets Postgres and runs on SQLite locally.
- **Mobile local storage: SQLCipher** (`sqflite_sqlcipher`) as PRD §21.2 recommends, because patient
  data on a field device must be encrypted at rest.
- **Dashboard: React + Vite + TypeScript.** Chosen over Next.js because the dashboard is an
  authenticated internal tool consuming a documented API — it needs no server rendering — and Vite's
  build is substantially faster on this machine.

---

## Open questions for the team

1. **The SIH problem statement ID.** PRD §1 lists it as a placeholder. A non-official source suggests
   `SIH26004 "EARLY OA DETECTION"`. This is **unverified** and deliberately not written into the
   project. Confirm from the SIH portal.
2. **OAI access.** Registering for an NDA account would materially strengthen the clinical branch.
   Approval takes days, so it should be started now if it is wanted.
3. **WOMAC licensing.** WOMAC is a licensed instrument. Only localisation *keys* are stored, never
   verbatim item text. The deployment authority must confirm permitted use and approved wording
   before field rollout.
4. **Clinical advisor sign-off** on the SPADI / FAAM / QuickDASH / PRWE item sets (D5).
