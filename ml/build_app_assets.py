"""Builds mobile/assets/models/ from the training run's real outputs.

WHAT THIS PRODUCES
------------------
1. ``model_manifest.json`` — what the app reads to decide whether a branch is
   allowed to score at all (see ``mobile/lib/ai/tflite_branch.dart``).
2. ``fusion_config.json`` — the fusion coefficients the app reads.
3. ``<model_id>.tflite`` — copies of the verified artefacts.

WHY THIS SCRIPT VERIFIES INSTEAD OF TRUSTING
--------------------------------------------
The app decides what it may claim by reading the manifest, so a manifest that
disagrees with the protocols would let the product assert something the source
of truth does not. Every value here is checked against BOTH:

  * ``ml/artifacts/imu_branch_metrics.json`` — the actual training run, and
  * ``protocols/<joint>/protocol.json`` — the declared model contract.

and the script fails loudly on any disagreement, rather than writing whatever
it happened to read. The failure modes it catches are not hypothetical:

  * a protocol marked ``trained`` with no measured metrics (PRD §26.5);
  * a manifest whose ``feature_keys`` disagree with the order the model was
    trained in — a silent reorder produces confident nonsense, so this is the
    single most damaging drift possible;
  * a research-grade feature (PRD §15.3) sneaking into the shipped primary
    model, which is exactly how a rule gets broken without anyone deciding to
    break it;
  * a manifest entry for an artefact that does not exist.

Run from the repository root::

    python ml/build_app_assets.py
"""

from __future__ import annotations

import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
METRICS_PATH = ROOT / "ml" / "artifacts" / "imu_branch_metrics.json"
ASSET_DIR = ROOT / "mobile" / "assets" / "models"
PROTOCOL_DIR = ROOT / "protocols"

#: Branch whose trained artefacts we bundle.
TRAINED_BRANCH = "imu_temporal"

#: Feature keys marked research-grade in the protocol feature pipeline.
#: PRD §15.3 keeps high-frequency vibration variance an auxiliary signal; it
#: must never reach the shipped primary model.
RESEARCH_GRADE = {"imu_gyro_hf_variance", "imu_relative_phase_lag"}

#: Mirrors FusionConfig.uncalibratedDefault in mobile/lib/ai/fusion.dart.
#: Kept deliberately identical: this file exists so the ml/ pipeline has a
#: target to write fitted coefficients into later, NOT because these numbers
#: were fitted here. They were not.
FUSION_WEIGHTS = {
    "imu_temporal": 0.40,
    "clinical_tabular": 0.35,
    "stage1_localisation": 0.15,
    "camera_temporal": 0.10,
    "imaging": 0.05,
}


class BuildError(RuntimeError):
    """Raised when the declared contract and the measured result disagree."""


def load_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def expected_metrics(run: dict) -> dict:
    """The metrics block a protocol must carry for one training run.

    Built from the run itself so there is exactly one place that decides what a
    declared metric looks like — the protocol copy and the manifest copy are
    then compared against this, which is how a hand-typed number gets caught.
    """
    op = run["operating_point"]
    return {
        "evaluation": (
            f"StratifiedGroupKFold, {run['cv_folds']} folds, grouped on subject_id; "
            f"all values are out-of-fold over {run['n_trials']} trials"
        ),
        "validation_scope": "single dataset - no external validation and no NER validation",
        "auc_grouped_cv_mean": run["auc_mean"],
        "auc_grouped_cv_std": run["auc_std"],
        "auc_pooled_oof": run["auc_pooled_oof"],
        "average_precision": run["average_precision"],
        "brier": run["brier"],
        "threshold": op["threshold"],
        "target_sensitivity": op["target_sensitivity"],
        "operating_point_sensitivity": op["sensitivity"],
        "operating_point_specificity": op["specificity"],
        "ppv_at_dataset_prevalence": op["ppv_at_dataset_prevalence"],
        "npv_at_dataset_prevalence": op["npv_at_dataset_prevalence"],
        "prevalence": op["prevalence"],
        "n_trials": run["n_trials"],
        "n_participants": run["n_participants"],
        "n_positive_participants": run["n_positive_participants"],
        "n_negative_participants": run["n_negative_participants"],
        "calibration": "not_calibrated",
    }


def diff(actual: dict, expected: dict, label: str) -> list[str]:
    problems = []
    for key, want in expected.items():
        got = actual.get(key, "<absent>")
        if got != want:
            problems.append(f"{label}: {key} is {got!r} but the training run says {want!r}")
    for key in actual:
        if key not in expected:
            problems.append(f"{label}: carries undeclared key {key!r}")
    return problems


def build() -> tuple[dict, list[str], list[tuple[str, pathlib.Path]]]:
    run_metrics = load_json(METRICS_PATH)

    manifest_models: list[dict] = []
    problems: list[str] = []
    artefacts: list[tuple[str, pathlib.Path]] = []

    for protocol_path in sorted(PROTOCOL_DIR.glob("*/protocol.json")):
        protocol = load_json(protocol_path)
        joint = protocol["joint_id"]
        pipeline_keys = {f["key"] for f in protocol.get("feature_pipeline", [])}

        for spec in protocol.get("models", []):
            if spec["branch"] != TRAINED_BRANCH:
                continue
            if spec["training_status"] != "trained":
                continue

            where = f"{joint}/{spec['model_id']}"
            run_key = f"{joint}_primary"
            if run_key not in run_metrics:
                problems.append(f"{where}: no training run recorded as {run_key!r}")
                continue

            run = run_metrics[run_key]

            # The id is what names the asset file, so a mismatch here would
            # silently ship a model under a name nobody trained.
            if run["model_id"] != spec["model_id"]:
                problems.append(
                    f"{where}: training run produced {run['model_id']!r}"
                )

            declared = spec.get("metrics")
            if not declared:
                problems.append(f"{where}: marked trained but carries no metrics (PRD §26.5)")
            else:
                problems.extend(diff(declared, expected_metrics(run), where))

            features = run["features"]
            unknown = [k for k in features if k not in pipeline_keys]
            if unknown:
                problems.append(
                    f"{where}: features absent from the protocol pipeline: {unknown}"
                )

            research = [k for k in features if k in RESEARCH_GRADE]
            if research:
                problems.append(
                    f"{where}: research-grade feature in the shipped model: {research} (PRD §15.3)"
                )

            source = ROOT / "ml" / "artifacts" / run["artifact"]
            if not source.is_file():
                problems.append(f"{where}: artefact missing at {source}")
                continue
            artefacts.append((spec["model_id"], source))

            manifest_models.append(
                {
                    "model_id": spec["model_id"],
                    "version": spec["version"],
                    "training_status": spec["training_status"],
                    "feature_keys": features,
                    "dataset": spec.get("dataset", "unspecified"),
                    # Flat on purpose: tflite_branch.dart's metricsSummary only
                    # renders num/String values, so a nested object would be
                    # written and never shown to the specialist.
                    "metrics": {k: v for k, v in declared.items()},
                    "output_kind": "risk_score",
                    "placement_note": spec.get("placement_note"),
                    "limitations": spec.get("limitations", []),
                    "threshold": run["operating_point"]["threshold"],
                }
            )

    return (
        {
            "generated_at": _generated_at(),
            "provenance": (
                "Generated by ml/build_app_assets.py from ml/artifacts/"
                "imu_branch_metrics.json and protocols/. Every metric is "
                "out-of-fold from participant-grouped cross-validation on "
                "Voisard et al. 2025 (CC BY 4.0, non-commercial). Trained and "
                "verified, NOT clinically validated, and not validated in the "
                "North Eastern Region of India."
            ),
            "models": manifest_models,
        },
        problems,
        artefacts,
    )


def _generated_at() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def main() -> int:
    if not METRICS_PATH.is_file():
        print(f"missing {METRICS_PATH} — run ml/imu_temporal/train.py first", file=sys.stderr)
        return 1

    manifest, problems, artefacts = build()

    if problems:
        print("REFUSING to write app assets; contract and run disagree:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    if not manifest["models"]:
        print("REFUSING to write an empty manifest; no trained model found", file=sys.stderr)
        return 1

    ASSET_DIR.mkdir(parents=True, exist_ok=True)

    manifest_path = ASSET_DIR / "model_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"  write  {manifest_path.relative_to(ROOT)} ({len(manifest['models'])} models)")

    fusion = {
        "weights": FUSION_WEIGHTS,
        "confidence_exponent": 1.0,
        "calibrated": False,
        "provenance": (
            "UNVALIDATED DEFAULT — declared engineering weights, not fitted "
            "coefficients. Only one modality has labelled training data, so "
            "there is nothing to fit fusion against yet and PRD §15.5 remains "
            "unmet. ml/build_app_assets.py writes this file so fitted "
            "coefficients have an obvious destination later."
        ),
        "dataset": "Voisard et al. 2025 (branch metrics only; fusion itself not fitted)",
        "fitted_at": None,
    }
    fusion_path = ASSET_DIR / "fusion_config.json"
    fusion_path.write_text(json.dumps(fusion, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"  write  {fusion_path.relative_to(ROOT)}")

    for model_id, source in artefacts:
        target = ASSET_DIR / f"{model_id}.tflite"
        shutil.copyfile(source, target)
        print(f"  copy   {target.relative_to(ROOT)} ({target.stat().st_size} bytes)")

    # A stale artefact left over from an earlier run would be loaded in
    # preference to nothing at all, which is how an old model ships unnoticed.
    expected = {f"{model_id}.tflite" for model_id, _ in artefacts}
    for stale in sorted(ASSET_DIR.glob("*.tflite")):
        if stale.name not in expected:
            stale.unlink()
            print(f"  remove {stale.relative_to(ROOT)} (no longer trained)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
