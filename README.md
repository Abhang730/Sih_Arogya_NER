# Arogya-NER

**Smart Clinic in a Pocket** — an offline-first, multimodal musculoskeletal and osteoarthritis
risk-screening platform for the North Eastern Region of India.

> **Screening, not diagnosis.** Arogya-NER supports screening, risk indication and referral. It is
> not a standalone diagnostic device and does not claim clinical validity. Every model in this
> repository is a research prototype unless its protocol metadata says otherwise, and no result may
> be presented as a clinical diagnosis.

Project: **Arogya-NER** · Team: **TerraNexus** · Event: Smart India Hackathon 2026
Problem statement: AI-assisted early detection of osteoarthritis risk markers in the North Eastern Region

---

## What this is

A two-stage screening platform, deliberately built as two stages rather than one black box:

| Stage | Question it answers | How |
|---|---|---|
| **Stage 1** | *Where* should we investigate? | Whole-body questionnaire, then a short camera movement screen producing 33 pose landmarks, gait/posture features and a joint-by-joint triage map. |
| **Stage 2** | *What* do we know about the selected joint? | A joint-specific protocol: validated questionnaire, targeted camera movement tests, a reusable BLE IMU pod, optional existing imaging — combined by a confidence-aware fusion layer into a screening indication and referral priority. |

The platform is configuration-driven. Adding a joint means adding a protocol file, not editing screen
code.

---

## Repository layout

```
protocols/          Joint protocol definitions — the single source of truth (§12.1)
  schema/           JSON Schema every protocol validates against
  core/             Landmark topology and shared definitions
  knee/ hip/ ...    One directory per joint
  index.json        Registry the app and backend both read
mobile/             Flutter Android/iOS application (offline-first)
ai/  (within mobile) Branch scoring, fusion, Stage-1 localisation
ml/                 Real-data training pipeline and TFLite export
backend/            FastAPI gateway (PRD §22 API surface)
specialist_web/     Specialist / analytics dashboard (PRD §23)
hardware/           ESP32-S3 Motion Pod firmware and sensor protocol
tools/              Protocol linter, asset sync
docs/               PRD, technical design, decision log, data sources
```

---

## The most important design decision

The PRD makes honesty a **binding** guardrail (§1.2), not an aspiration. That is enforced structurally
rather than by reviewer discipline:

- **Protocols declare what is real.** Every model carries a `training_status`. A branch marked
  `untrained_insufficient_data` cannot produce a score at all — the code path returns "unavailable"
  and there is no way to build a score object that both has a value and is unavailable.
- **A missing measurement is never a zero.** Fusion returns `null`, not `0.0`, when nothing could be
  scored, because `0.0` reads as "no risk" while the truth is "not assessed".
- **Every score carries its own provenance.** Model id, version, training status, confidence,
  placement caveats and limitations travel inside the score object, so a number cannot lose its
  context between the model and the report.
- **A `.tflite` file alone cannot activate a claim.** A model only becomes usable when a generated
  manifest entry also records `training_status: trained` with real evaluation metrics.
- **The linter and the test suite enforce all of the above** (`tools/lint_protocols.py`,
  `mobile/test/`), so drift fails the build instead of reaching a patient.

---

## Getting started

### Protocols

```bash
python -m venv .venv
./.venv/Scripts/python.exe -m pip install jsonschema
./.venv/Scripts/python.exe tools/lint_protocols.py      # schema + cross-protocol integrity
./.venv/Scripts/python.exe tools/sync_protocols.py      # mirror protocols into the Flutter bundle
```

### Mobile app

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

`tools/sync_protocols.py` must be run after editing anything in `protocols/`. A test fails if the
bundled mirror drifts from the source, so this cannot be forgotten silently.

---

## Current implementation status

Honest status, by design. The PRD's own maturity column reads the same way.

| Area | State |
|---|---|
| Protocol engine — 6 joints, schema-validated, registry | **Complete** |
| Questionnaire scoring (WOMAC, verified arithmetic) | **Complete** |
| Pose abstraction + ML Kit engine + synthetic engine | **Complete** |
| Capture quality gate (§9.4) | **Complete** |
| Camera feature extraction (angles, gait, sit-to-stand, posture) | **Complete**, heuristics documented as heuristics |
| AI branch + fusion layer with confidence-aware weighting | **Complete**; weights are declared uncalibrated defaults |
| Stage-1 joint risk localisation | **Wired**; reports `insufficient_data` per joint until a model is trained |
| Trained models | **None yet.** `training_status` is `planned`/`untrained_insufficient_data` and the app says so on screen |
| Specialist dashboard, backend API | **Not built yet** |
| Motion Pod firmware | **Not built yet** |

**No model in this repository is clinically validated, and none is presented as such.**

---

## Documentation

- `docs/PRD_extracted_source.txt` — the master PRD/PTD as supplied
- `docs/DECISIONS.md` — decision log, including every deviation from the PRD and why
- `docs/DATA_SOURCES.md` — the real datasets, their licences and their limits

## Safety and privacy

- Raw video is **not retained** by default; only derived landmarks and features are stored (§25.2).
- Patient records use a generated **Arogya Patient ID**; the identity field is masked and tokenised,
  and is never the operational identifier (§7.2).
- No personal or patient data is committed to this repository. `.gitignore` excludes local
  databases, dataset downloads and model binaries.
