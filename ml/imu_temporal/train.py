"""Train the IMU branch for knee OA and hip OA (PRD §17.2, §26, §27.1).

WHAT THIS TRAINS
----------------
Binary classification of cohort membership: KOA vs HS (knee), HOA vs HS (hip),
from the nine engineered IMU features computed in ``ml/common/imu_features.py``.

The target is **cohort membership**, not a clinical diagnosis and not a
Kellgren-Lawrence grade. That matches what the protocol's model metadata already
declares, and it avoids the trap PRD §26.3 warns about of forcing a grade
prediction simply because an imaging dataset happens to exist.

THREE METHODOLOGICAL DECISIONS THAT DECIDE WHETHER THE NUMBERS MEAN ANYTHING
--------------------------------------------------------------------------
1. **Participant-grouped cross-validation.** The dataset has multiple trials per
   participant (18 KOA participants produce 78 trials). A random split would put
   the same person in train and test, and the model would score well by
   memorising the individual rather than the condition. Every reported metric
   uses ``StratifiedGroupKFold`` on ``subject_id``.

2. **The research-grade features are excluded from the primary model.** PRD §15.3
   requires high-frequency vibration variance to stay an auxiliary signal rather
   than a core decision feature. That is inconvenient here, because it is also
   the single strongest univariate discriminator (AUC 0.134 for KOA vs HS). So
   both variants are trained and reported: the shipped primary model without
   them, and a clearly-labelled exploratory variant with them. The gap between
   the two is itself a finding, and it is reported rather than quietly exploited.

3. **Standardisation is baked into the exported graph.** The scaler is the first
   layer of the network, so the device sends raw feature values. Shipping a
   scaler separately would mean the app has to reproduce its exact arithmetic —
   one more chance for train/serve skew, for no benefit.

Run::

    python ml/imu_temporal/train.py
"""

from __future__ import annotations

import json
import pathlib
import sys

import numpy as np
import pandas as pd
import tensorflow as tf
from sklearn.metrics import (
    average_precision_score,
    brier_score_loss,
    roc_auc_score,
    roc_curve,
)
from sklearn.model_selection import StratifiedGroupKFold

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent))

from ml.common.dataset import load_cohort_trials  # noqa: E402
from ml.common.imu_features import (  # noqa: E402
    FEATURE_ORDER,
    RESEARCH_GRADE_FEATURES,
    ImuTrial,
    extract_features,
)

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
ARTIFACT_DIR = ROOT / "ml" / "artifacts"

RANDOM_STATE = 20260928
N_SPLITS = 5

#: Target sensitivity used to pick the operating point. PRD §33 rates
#: under-referral as High impact and over-referral as Medium, so the operating
#: point deliberately favours sensitivity.
TARGET_SENSITIVITY = 0.90

PRIMARY_FEATURES = tuple(k for k in FEATURE_ORDER if k not in RESEARCH_GRADE_FEATURES)
RESEARCH_FEATURES = tuple(FEATURE_ORDER)


def build_feature_table(cohorts: list[str]) -> pd.DataFrame:
    """One row per trial: features plus the label and grouping keys."""
    rows = []
    for cohort in cohorts:
        for record in load_cohort_trials(cohort):
            trial = ImuTrial(
                sample_rate_hz=record.sample_rate_hz,
                proximal=record.windowed(record.lower_back),
                distal=record.windowed(record.left_foot),
            )
            features = extract_features(trial)
            rows.append(
                {
                    "trial_id": record.trial_id,
                    "subject_id": record.subject_id,
                    "cohort": record.cohort,
                    "age": record.age,
                    "bmi": record.bmi,
                    **{k: features.get(k, np.nan) for k in FEATURE_ORDER},
                }
            )
    table = pd.DataFrame(rows)
    return table


def _build_model(n_features: int, mean: np.ndarray, std: np.ndarray) -> tf.keras.Model:
    """A shallow MLP with standardisation baked in as explicit arithmetic.

    Standardisation is written as `(x - mean) / std` over constant tensors rather
    than using the `Normalization` layer. That layer stores its statistics as
    non-trainable variables, and the TFLite converter does not reliably preserve
    them — which produced a broken artefact that still returned a number
    (observed: Keras 0.00 vs TFLite 1.00 for the same input). Explicit constant
    arithmetic folds into the graph and converts cleanly.

    Kept deliberately small: with 106 participants, a wide network would fit the
    participants rather than the condition.
    """
    inputs = tf.keras.Input(shape=(n_features,), name="features")
    mean_const = tf.constant(mean.reshape(1, -1), dtype=tf.float32, name="mean")
    std_const = tf.constant(std.reshape(1, -1), dtype=tf.float32, name="std")

    x = tf.keras.layers.Lambda(
        lambda values: (values - mean_const) / std_const,
        name="standardise",
    )(inputs)
    x = tf.keras.layers.Dense(16, activation="relu", name="hidden_1")(x)
    x = tf.keras.layers.Dropout(0.3, name="dropout")(x)
    x = tf.keras.layers.Dense(8, activation="relu", name="hidden_2")(x)
    outputs = tf.keras.layers.Dense(1, activation="sigmoid", name="risk_score")(x)

    return tf.keras.Model(inputs=inputs, outputs=outputs, name="arogya_imu_branch")


def _auc(y_true: np.ndarray, y_score: np.ndarray) -> float:
    if len(np.unique(y_true)) < 2:
        return float("nan")
    return float(roc_auc_score(y_true, y_score))


def _confusion(
    y_true: np.ndarray, y_score: np.ndarray, threshold: float
) -> dict[str, float]:
    """Confusion-matrix derived metrics at one threshold."""
    positive = y_true == 1
    predicted = y_score >= threshold
    tp = int((predicted & positive).sum())
    fp = int((predicted & ~positive).sum())
    fn = int((~predicted & positive).sum())
    tn = int((~predicted & ~positive).sum())
    return {
        "threshold": float(threshold),
        "true_positive": tp,
        "false_positive": fp,
        "false_negative": fn,
        "true_negative": tn,
        "sensitivity": tp / (tp + fn) if (tp + fn) else float("nan"),
        "specificity": tn / (tn + fp) if (tn + fp) else float("nan"),
        "ppv_at_dataset_prevalence": tp / (tp + fp) if (tp + fp) else float("nan"),
        "npv_at_dataset_prevalence": tn / (tn + fn) if (tn + fn) else float("nan"),
        "prevalence": float(positive.mean()),
        "accuracy": (tp + tn) / len(y_true),
    }


def _operating_point(
    y_true: np.ndarray, y_score: np.ndarray, target_sensitivity: float
) -> dict:
    """Picks a decision threshold, preferring high sensitivity.

    Uses the ROC curve rather than a hand-rolled threshold sweep. ROC curve
    outputs thresholds in DECREASING order with true-positive-rate increasing,
    so the first index that reaches the target sensitivity is the HIGHEST
    threshold that does so — which is the one with the fewest false positives,
    i.e. the best specificity for the required sensitivity.

    Falls back to Youden's J when the target sensitivity is unreachable, so a
    result is still reported rather than the run failing.
    """
    fpr, tpr, thresholds = roc_curve(y_true, y_score)

    finite = np.isfinite(thresholds)
    thresholds = thresholds[finite]
    tpr = tpr[finite]
    fpr = fpr[finite]

    reaching = np.where(tpr >= target_sensitivity)[0]
    if reaching.size:
        index = int(reaching[0])
        metrics = _confusion(y_true, y_score, float(thresholds[index]))
        metrics["selection"] = f"highest threshold reaching sensitivity >= {target_sensitivity}"
        return metrics

    youden = tpr - fpr
    index = int(np.argmax(youden))
    metrics = _confusion(y_true, y_score, float(thresholds[index]))
    metrics["selection"] = (
        f"target sensitivity {target_sensitivity} unreachable; "
        f"fell back to Youden's J"
    )
    metrics["target_sensitivity"] = target_sensitivity
    return metrics


def cross_validate(
    table: pd.DataFrame,
    feature_keys: tuple[str, ...],
    target_cohort: str,
    label_name: str,
) -> dict:
    """Participant-grouped CV, returning honest metrics and out-of-fold scores."""
    frame = table[table["cohort"].isin(["HS", target_cohort])].copy()
    frame = frame.dropna(subset=list(feature_keys))

    x = frame[list(feature_keys)].to_numpy(dtype=np.float64)
    y = (frame["cohort"] == target_cohort).to_numpy(dtype=np.int64)
    groups = frame["subject_id"].to_numpy()

    splitter = StratifiedGroupKFold(
        n_splits=N_SPLITS, shuffle=True, random_state=RANDOM_STATE
    )

    oof = np.full(len(y), np.nan)
    fold_aucs: list[float] = []

    for train_index, test_index in splitter.split(x, y, groups):
        x_train, x_test = x[train_index], x[test_index]
        y_train, y_test = y[train_index], y[test_index]

        mean = x_train.mean(axis=0)
        std = x_train.std(axis=0)
        std[std == 0] = 1.0

        model = _build_model(x.shape[1], mean, std)
        model.compile(
            optimizer=tf.keras.optimizers.Adam(learning_rate=3e-3),
            loss=tf.keras.losses.BinaryCrossentropy(),
            metrics=[tf.keras.metrics.AUC(name="auc")],
        )

        # Class weighting matters: KOA has 78 trials against HS's 360.
        negatives = int((y_train == 0).sum())
        positives = int((y_train == 1).sum())
        class_weight = {0: 1.0, 1: negatives / max(positives, 1)}

        model.fit(
            x_train,
            y_train,
            epochs=180,
            batch_size=32,
            verbose=0,
            class_weight=class_weight,
            callbacks=[tf.keras.callbacks.EarlyStopping(
                monitor="loss", patience=25, restore_best_weights=True
            )],
        )

        fold_scores = model.predict(x_test, verbose=0).ravel()
        oof[test_index] = fold_scores
        fold_aucs.append(_auc(y_test, fold_scores))

    valid = ~np.isnan(oof)
    y_valid = y[valid]
    score_valid = oof[valid]

    op_metrics = _operating_point(y_valid, score_valid, TARGET_SENSITIVITY)

    metrics = {
        "label": label_name,
        "target_cohort": target_cohort,
        "n_trials": int(len(y_valid)),
        "n_participants": int(frame["subject_id"].nunique()),
        "n_positive_trials": int(y_valid.sum()),
        "n_negative_trials": int((y_valid == 0).sum()),
        "n_positive_participants": int(
            frame.loc[(frame["cohort"] == target_cohort), "subject_id"].nunique()
        ),
        "n_negative_participants": int(
            frame.loc[(frame["cohort"] == "HS"), "subject_id"].nunique()
        ),
        "cv_folds": N_SPLITS,
        "cv_grouping": "participant (subject_id) — trials from one person never split across folds",
        "auc_mean": float(np.nanmean(fold_aucs)),
        "auc_std": float(np.nanstd(fold_aucs)),
        "auc_pooled_oof": _auc(y_valid, score_valid),
        "average_precision": float(average_precision_score(y_valid, score_valid)),
        "brier": float(brier_score_loss(y_valid, score_valid)),
        "operating_point": {
            "threshold": op_metrics["threshold"],
            "target_sensitivity": TARGET_SENSITIVITY,
            "sensitivity": op_metrics.get("sensitivity"),
            "specificity": op_metrics.get("specificity"),
            "ppv_at_dataset_prevalence": op_metrics.get("ppv_at_dataset_prevalence"),
            "npv_at_dataset_prevalence": op_metrics.get("npv_at_dataset_prevalence"),
            "prevalence": op_metrics.get("prevalence"),
            "selection": op_metrics.get("selection"),
        },
        "features": list(feature_keys),
    }
    return metrics


def fit_final(
    table: pd.DataFrame, feature_keys: tuple[str, ...], target_cohort: str
) -> tuple[tf.keras.Model, np.ndarray, np.ndarray]:
    """Trains on every available trial for export."""
    frame = table[table["cohort"].isin(["HS", target_cohort])].copy()
    frame = frame.dropna(subset=list(feature_keys))

    x = frame[list(feature_keys)].to_numpy(dtype=np.float64)
    y = (frame["cohort"] == target_cohort).to_numpy(dtype=np.int64)

    mean = x.mean(axis=0)
    std = x.std(axis=0)
    std[std == 0] = 1.0

    model = _build_model(x.shape[1], mean, std)
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=3e-3),
        loss=tf.keras.losses.BinaryCrossentropy(),
    )
    negatives = int((y == 0).sum())
    positives = int((y == 1).sum())
    model.fit(
        x,
        y,
        epochs=140,
        batch_size=32,
        verbose=0,
        class_weight={0: 1.0, 1: negatives / max(positives, 1)},
    )
    return model, mean, std


def fold_standardisation(
    model: tf.keras.Model, mean: np.ndarray, std: np.ndarray
) -> tf.keras.Model:
    """Returns an equivalent model that consumes RAW feature values.

    The trained model standardises its input inside a `Lambda` layer. That layer
    does not survive TFLite conversion reliably: the exported graph returned
    NaN for every input while Keras returned a clean score, which is the worst
    possible failure mode because a NaN only surfaces if something checks for
    it.

    Rather than fight the converter, the standardisation is folded into the
    first Dense layer's weights. That is exact algebra, not an approximation:

        relu(((x - mean) / std) @ W + b)
            == relu(x @ (W / std) + (b - (mean / std) @ W))

    The folded model contains nothing but Dense layers, so there is no captured
    constant for the converter to mishandle.
    """
    mean = np.asarray(mean, dtype=np.float64)
    std = np.asarray(std, dtype=np.float64)

    first = model.get_layer("hidden_1")
    weights, bias = first.get_weights()
    if weights.shape[0] != mean.shape[0]:
        raise AssertionError(
            f"standardisation has {mean.shape[0]} statistics but the first "
            f"layer expects {weights.shape[0]} features"
        )

    folded_weights = (weights / std.reshape(-1, 1)).astype(np.float32)
    folded_bias = (bias - ((mean / std) @ weights)).astype(np.float32)

    inputs = tf.keras.Input(shape=(int(mean.shape[0]),), name="features")
    x = tf.keras.layers.Dense(16, activation="relu", name="hidden_1")(inputs)
    x = tf.keras.layers.Dense(8, activation="relu", name="hidden_2")(x)
    outputs = tf.keras.layers.Dense(1, activation="sigmoid", name="risk_score")(x)

    folded = tf.keras.Model(
        inputs=inputs, outputs=outputs, name="arogya_imu_branch_export"
    )
    folded.get_layer("hidden_1").set_weights([folded_weights, folded_bias])
    folded.get_layer("hidden_2").set_weights(model.get_layer("hidden_2").get_weights())
    folded.get_layer("risk_score").set_weights(
        model.get_layer("risk_score").get_weights()
    )
    return folded


def export_tflite(model: tf.keras.Model, path: pathlib.Path) -> int:
    """Exports a float32 TFLite model built from Dense layers only.

    Expects the folded model from `fold_standardisation`, which is already
    consuming raw features.

    Uses the plain Keras converter. The concrete-function route was tried here
    first and produced an artefact that returned NaN for every input — including
    an all-zeros vector — because the exported graph's output tensor was not
    connected to the computation. With no lambda and no normalisation layer left
    in the model there is nothing for the standard path to lose, so the simpler
    and far better-supported route is the correct one.
    """
    path.parent.mkdir(parents=True, exist_ok=True)

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    # Deliberately NO quantisation. The artefact is a few kilobytes, so dynamic
    # range quantisation would buy nothing and costs fidelity in exactly the
    # place it matters least and is hardest to notice. PRD §10.6 targets INT8 for
    # the on-device Stage-1 model; this branch has no such requirement.

    tflite_bytes = converter.convert()
    path.write_bytes(tflite_bytes)
    return len(tflite_bytes)


def verify_tflite(path: pathlib.Path, model: tf.keras.Model, samples: np.ndarray) -> float:
    """Loads the exported artefact and compares it against the folded model.

    A conversion that silently changed behaviour is worse than a failed export,
    so this asserts agreement rather than assuming it, over several samples.

    Three things are checked, because each one has failed at least once here:

    1. The artefact produces finite scores. An all-zeros input is included
       deliberately — it cannot legitimately produce NaN or infinity, so it
       catches an output tensor left unconnected, where garbage memory is read
       and reported as a number.
    2. TFLite agrees with the in-process model on real feature vectors.
    3. The comparison is NaN-safe. `abs(nan - x) > eps` is False, so a purely
       threshold-based check lets a non-finite divergence pass as if it were
       fine. That exact bug is why the finiteness check is explicit and not
       left to the tolerance.
    """
    interpreter = tf.lite.Interpreter(model_path=str(path))
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()[0]
    output_details = interpreter.get_output_details()[0]

    n_features = int(input_details["shape"][-1])

    def run(x: np.ndarray) -> float:
        interpreter.set_tensor(input_details["index"], x.astype(np.float32))
        interpreter.invoke()
        return float(interpreter.get_tensor(output_details["index"]).ravel()[0])

    probe = run(np.zeros((1, n_features), dtype=np.float32))
    if not np.isfinite(probe):
        raise AssertionError(
            f"TFLite returned {probe} for an all-zeros input, which is never "
            f"legitimate — the exported graph is not computing what it should"
        )

    worst = 0.0
    for i in range(samples.shape[0]):
        x = samples[i].reshape(1, -1).astype(np.float32)
        tflite_score = run(x)
        keras_score = float(model.predict(x, verbose=0).ravel()[0])

        if not np.isfinite(tflite_score):
            raise AssertionError(
                f"TFLite produced a non-finite score ({tflite_score}) for sample {i} "
                f"while Keras produced {keras_score:.5f}"
            )
        if not np.isfinite(keras_score):
            raise AssertionError(f"Keras produced a non-finite score for sample {i}")

        delta = abs(tflite_score - keras_score)
        worst = max(worst, delta)
        if delta > 2e-3:
            raise AssertionError(
                f"TFLite export diverged from Keras by {delta:.5f} on sample {i} "
                f"(keras={keras_score:.5f}, tflite={tflite_score:.5f})"
            )
    return worst


def main() -> int:
    # Seed before any model is built. Dense initialisers are otherwise random, so
    # unseeded runs report different metrics every time and the values written
    # into the protocol would silently drift away from a fresh training run.
    tf.keras.utils.set_random_seed(RANDOM_STATE)

    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)

    print("building feature table ...")
    table = build_feature_table(["HS", "KOA", "HOA"])
    print(f"  {len(table)} trials, {table['subject_id'].nunique()} participants")

    all_metrics = {}

    targets = [
        ("KOA", "knee_oa_risk_marker", "knee"),
        ("HOA", "hip_oa_risk_marker", "hip"),
    ]

    for target_cohort, label, joint in targets:
        for variant, feature_keys in (
            ("primary", PRIMARY_FEATURES),
            ("research", RESEARCH_FEATURES),
        ):
            # Named after the branch, not the architecture: the PRD §17.2 TCN
            # is not what the available data supports, and an id asserting one
            # would misdescribe the artefact shipped under it.
            model_id = f"{joint}_imu_temporal"
            print(f"\n{'=' * 72}")
            print(f"{joint.upper()}  /  {target_cohort} vs HS  /  {variant} features")
            print(f"  features ({len(feature_keys)}): {', '.join(feature_keys)}")
            print(f"{'=' * 72}")

            metrics = cross_validate(table, feature_keys, target_cohort, label)
            metrics["variant"] = variant
            metrics["model_id"] = model_id

            print(f"  AUC (grouped CV)   : {metrics['auc_mean']:.3f} "
                  f"± {metrics['auc_std']:.3f}")
            print(f"  AUC (pooled OOF)   : {metrics['auc_pooled_oof']:.3f}")
            print(f"  average precision  : {metrics['average_precision']:.3f}")
            print(f"  Brier score        : {metrics['brier']:.3f}")
            op = metrics["operating_point"]
            print(f"  operating point    : threshold {op['threshold']:.3f} "
                  f"-> sensitivity {op['sensitivity']:.3f}, "
                  f"specificity {op['specificity']:.3f}")
            print(f"  participants       : {metrics['n_positive_participants']} positive "
                  f"/ {metrics['n_negative_participants']} healthy")

            all_metrics[f"{joint}_{variant}"] = metrics

            if variant == "primary":
                print("  fitting final model and exporting TFLite ...")
                model, mean, std = fit_final(table, feature_keys, target_cohort)
                export_model = fold_standardisation(model, mean, std)
                path = ARTIFACT_DIR / f"{model_id}.tflite"
                size = export_tflite(export_model, path)

                frame = table[table["cohort"].isin(["HS", target_cohort])].dropna(
                    subset=list(feature_keys)
                )
                # Several samples, not one: a single point can happen to agree
                # by luck while the graph is broken everywhere else.
                samples = frame[list(feature_keys)].to_numpy(dtype=np.float64)[:8]
                worst_delta = verify_tflite(path, export_model, samples)

                # Folding is exact algebra, so hold it to that standard before
                # blaming the converter for anything downstream.
                fold_delta = float(
                    np.max(
                        np.abs(
                            export_model.predict(samples, verbose=0).ravel()
                            - model.predict(samples, verbose=0).ravel()
                        )
                    )
                )
                if not np.isfinite(fold_delta) or fold_delta > 1e-5:
                    raise AssertionError(
                        f"folded export diverged from the trained model by "
                        f"{fold_delta:.2e}"
                    )

                print(f"  exported           : {path.name} ({size / 1024:.1f} KiB)")
                print(f"  verification       : TFLite agrees with Keras on "
                      f"{samples.shape[0]} samples (worst delta {worst_delta:.2e})")

                all_metrics[f"{joint}_primary"]["artifact"] = path.name
                all_metrics[f"{joint}_primary"]["artifact_bytes"] = size

    metrics_path = ARTIFACT_DIR / "imu_branch_metrics.json"
    metrics_path.write_text(json.dumps(all_metrics, indent=2), encoding="utf-8")
    print(f"\nwrote {metrics_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
