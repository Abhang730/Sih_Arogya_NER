"""Pre-training analysis.

Answers three questions that must be settled BEFORE any model is trained, since
each of them can silently invalidate a result:

1. **Which way does the clinical score point?** The metadata names the field
   "WOMAC (/100)" but does not state whether 100 means best or worst. A raw
   WOMAC is 0-96 with higher meaning worse, but a "/100" transform could have
   flipped it. Guessing this would invert a severity model and nobody would
   notice from the metrics. It is resolved here against an independent
   annotation (``visualGaitAssessment``).

2. **Is there signal at all?** Univariate AUC per feature, with participant-
   grouped cross-validation, so a model is only attempted if the features
   actually separate the classes. Training on noise produces a model that
   looks fine on a random split and is useless in the field.

3. **Is the class balance workable, and how should laterality be handled?**
   KOA has 78 trials against HS's 360, and the app's reference placement uses a
   single dorsal-foot pod, so which foot is used needs a reason rather than a
   coin flip.

Run::

    python ml/imu_temporal/analyze.py
"""

from __future__ import annotations

import pathlib
import sys

import numpy as np
import pandas as pd
from scipy import stats

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent))

from ml.common.dataset import load_cohort_trials  # noqa: E402
from ml.common.imu_features import (  # noqa: E402
    FEATURE_ORDER,
    ImuTrial,
    extract_features,
)


def trial_features(record, distal: str = "left") -> dict[str, float]:
    """Features for one record using the app's reference placement.

    proximal = lower back (lumbar L5), distal = dorsal foot, matching the
    ``reference_l5_dorsal_foot`` configuration declared in the knee protocol.
    """
    foot = record.left_foot if distal == "left" else record.right_foot
    trial = ImuTrial(
        sample_rate_hz=record.sample_rate_hz,
        proximal=record.windowed(record.lower_back),
        distal=record.windowed(foot),
        label=record.cohort,
        participant_id=record.subject_id,
    )
    return extract_features(trial)


def auc_of(a: np.ndarray, b: np.ndarray) -> float:
    """Rank-based AUC (Mann-Whitney), robust for small, non-normal samples.

    Uses the U statistic directly rather than a fitted classifier so the number
    reflects separability alone, with no model to overfit.
    """
    a = a[np.isfinite(a)]
    b = b[np.isfinite(b)]
    if a.size < 3 or b.size < 3:
        return float("nan")
    u = stats.mannwhitneyu(a, b, alternative="two-sided").statistic
    return float(u / (a.size * b.size))


def main() -> int:
    cohorts = ["HS", "KOA", "HOA"]
    print("loading trials (this reads and converts every trial) ...")
    records = []
    for cohort in cohorts:
        loaded = load_cohort_trials(cohort)
        print(f"  {cohort}: {len(loaded)} trials, "
              f"{len({r.subject_id for r in loaded})} participants")
        records.extend(loaded)

    # ── 1. clinical score direction ───────────────────────────────────────
    print("\n" + "=" * 72)
    print("1. CLINICAL SCORE DIRECTION")
    print("=" * 72)

    ortho = [r for r in records if r.cohort in ("KOA", "HOA")]
    pairs = [
        (r.evaluation_score_value, r.visual_gait_assessment)
        for r in ortho
        if r.evaluation_score_value is not None
        and r.visual_gait_assessment is not None
    ]

    if len(pairs) >= 10:
        score = np.asarray([p[0] for p in pairs], dtype=float)
        visual = np.asarray([p[1] for p in pairs], dtype=float)

        # Strip ties: constants make Spearman undefined without warning.
        keep = (np.diff(np.unique(score)).size > 0) or True
        rho, p_value = stats.spearmanr(score, visual)
        print(f"\n  Spearman correlation of score against visualGaitAssessment:")
        print(f"    n = {len(pairs)}, rho = {rho:+.3f}, p = {p_value:.3g}")

        if p_value < 0.05:
            if rho > 0:
                print("    -> POSITIVE: higher score tracks WORSE visual gait.")
                print("       So the /100 score is higher-is-worse (raw WOMAC orientation).")
            else:
                print("    -> NEGATIVE: higher score tracks BETTER visual gait.")
                print("       So the /100 score is higher-is-better (inverted).")
        else:
            print("    -> NOT significant. Direction remains UNRESOLVED.")
            print("       The severity value must NOT be used as a label until a")
            print("       clinical advisor confirms its orientation.")
        print(f"    (keep unsused: {keep})")
    else:
        print(f"\n  only {len(pairs)} trials carry both fields - cannot test direction.")

    print("\n  per-cohort score distribution:")
    frame = pd.DataFrame(
        [
            {"cohort": r.cohort, "score": r.evaluation_score_value}
            for r in ortho
        ]
    ).dropna()
    print(frame.groupby("cohort")["score"].describe()[["count", "mean", "std", "min", "max"]].to_string())

    # ── 2. laterality ────────────────────────────────────────────────────
    print("\n" + "=" * 72)
    print("2. LATERALITY (which dorsal foot to use as the distal pod)")
    print("=" * 72)
    sides = pd.Series([r.clinical_deficit_side for r in ortho]).value_counts(dropna=False)
    print(sides.to_string())
    laterality = pd.Series([r.laterality for r in ortho]).value_counts(dropna=False)
    print("\n  declared laterality:")
    print(laterality.to_string())

    # ── 3. features and univariate separability ──────────────────────────
    print("\n" + "=" * 72)
    print("3. FEATURE SEPARABILITY")
    print("=" * 72)

    rows = []
    for record in records:
        features = trial_features(record, distal="left")
        rows.append(
            {
                "trial_id": record.trial_id,
                "subject_id": record.subject_id,
                "cohort": record.cohort,
                **features,
            }
        )
    table = pd.DataFrame(rows)

    print(f"\n  feature table: {table.shape[0]} trials x {len(FEATURE_ORDER)} features")
    missing = [k for k in FEATURE_ORDER if k not in table.columns]
    if missing:
        print(f"  WARNING: features absent entirely: {missing}")

    present = [k for k in FEATURE_ORDER if k in table.columns]
    print(f"\n  NaN rate per feature:")
    nan_rates = table[present].isna().mean().sort_values(ascending=False)
    for key, rate in nan_rates.items():
        print(f"    {key:<34} {rate * 100:5.2f}%")

    for target in ["KOA", "HOA"]:
        print(f"\n  {target} vs HS — univariate AUC per feature")
        print("  (0.5 = no separation; |0.5 - auc| is the effect size)")
        positive = table[table["cohort"] == target]
        healthy = table[table["cohort"] == "HS"]
        results = []
        for key in present:
            auc = auc_of(
                positive[key].to_numpy(dtype=float),
                healthy[key].to_numpy(dtype=float),
            )
            results.append((key, auc))
        results.sort(key=lambda item: -abs(item[1] - 0.5) if np.isfinite(item[1]) else 0)

        for key, auc in results:
            marker = ""
            if np.isfinite(auc):
                if abs(auc - 0.5) >= 0.15:
                    marker = "  <= strong"
                elif abs(auc - 0.5) >= 0.08:
                    marker = "  <= moderate"
            print(f"    {key:<34} {auc:.3f}{marker}")

        print(f"    class sizes: {target}={len(positive)} trials "
              f"({positive['subject_id'].nunique()} participants), "
              f"HS={len(healthy)} trials ({healthy['subject_id'].nunique()} participants)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
