"""Loader for the Clinical Gait Signals dataset (Voisard et al. 2025).

DATASET FACTS, established by inspecting the archive rather than assuming
-----------------------------------------------------------------------
Layout::

    dataset/data/<group>/<COHORT>/<subject>/<trial>/<trial>_*.txt|json|png
    group in {healthy, neuro, ortho}

Cohorts and real trial counts:

    ========  ========  =======
    cohort    patients  trials
    ========  ========  =======
    HS            73      360     healthy subjects
    KOA           18       78     knee osteoarthritis      <- target
    HOA           15       74     hip osteoarthritis       <- target
    ACL           11       60     anterior cruciate injury
    PD            24      160     Parkinson's disease
    CVA           49      128     stroke
    CIPN          19       98     chemotherapy neuropathy
    RIL           51      398     radiation-induced leukoencephalopathy
    ========  ========  =======

Trial contents:
  * ``<trial>_processed_data.txt`` — all four sensors synchronised onto a common
    ``PacketCounter`` starting at 0, shaped (n, 37).
  * ``<trial>_raw_data_{HE,LB,LF,RF}.txt`` — per-sensor raw, full 10 channels.
  * ``<trial>_meta.json`` — demographics, pathology, sampling rate, u-turn
    boundaries and per-foot gait event indices.
  * ``<trial>_plot.png`` — pre-rendered figure.

Sensors: ``HE`` head, ``LB`` lower back, ``LF``/``RF`` left/right dorsal foot.
Sampling: 100 Hz (``meta.freq``).

UNITS — the single most dangerous detail in this file
-----------------------------------------------------
Measured from the data, not taken from the paper:

  * Accelerometer is in **m/s^2** (resting magnitude ~9.87, i.e. gravity).
  * Gyroscope is in **rad/s** (foot peak ~10 rad/s = ~575 deg/s, which is a
    plausible foot-swing rate; interpreting it as deg/s would be absurd).

The application and every feature definition in ``imu_features.py`` use **g**
and **degrees/second**, because that is what the ESP32-S3 + MPU-6050 Motion Pod
reports. Training on unconverted values would mean the exported model consumes
a feature vector in completely different units from the one the phone produces —
and it would still return confident numbers. So conversion happens here, once,
explicitly, and every consumer reads already-normalised units.

NaN HANDLING
------------
The foot channels contain genuine NaN samples (the raw export has gaps). They
are **not** silently interpolated: ``imu_signal_quality`` counts non-finite
samples as invalid, so a gappy trial is reported as lower quality instead of
having fabricated samples glued into it.

CLINICAL LABELS AVAILABLE
-------------------------
``meta.json`` carries ``age``, ``gender``, ``height``, ``weight``, ``BMI``,
``laterality``, ``clinicalDeficitSide``, an evaluation score (for the ortho
cohorts this is **WOMAC (/100)**), ``TUG`` and ``visualGaitAssessment``. Those
make a genuine tabular clinical branch possible in addition to the IMU branch.
"""

from __future__ import annotations

import dataclasses
import json
import pathlib
from typing import Iterator

import numpy as np
import pandas as pd

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DATASET_ROOT = ROOT / "ml" / "datasets" / "raw" / "clinical_gait_signals" / "dataset" / "data"

#: Standard gravity. The dataset's accelerometer is in m/s^2.
MPS2_PER_G: float = 9.80665

#: Radians to degrees. The dataset's gyroscope is in rad/s.
RAD_S_TO_DEG_S: float = 180.0 / np.pi

#: Cohort directory to (group, descriptive name, ortho target joint or None).
COHORTS: dict[str, tuple[str, str, str | None]] = {
    "HS": ("healthy", "Healthy subjects", None),
    "KOA": ("ortho", "Knee osteoarthritis", "knee"),
    "HOA": ("ortho", "Hip osteoarthritis", "hip"),
    "ACL": ("ortho", "Anterior cruciate ligament injury", None),
    "PD": ("neuro", "Parkinson's disease", None),
    "CVA": ("neuro", "Stroke (cerebrovascular accident)", None),
    "CIPN": ("neuro", "Chemotherapy-induced peripheral neuropathy", None),
    "RIL": ("neuro", "Radiation-induced leukoencephalopathy", None),
}

#: Sensor column prefixes in the processed file.
SENSORS: tuple[str, ...] = ("HE", "LB", "LF", "RF")


@dataclasses.dataclass
class TrialRecord:
    """One trial, with metadata and unit-normalised signals."""

    trial_id: str
    subject_id: str
    cohort: str
    group: str
    pathology: str | None

    sample_rate_hz: float

    #: Lower back pod — the proximal pod in the app's reference placement.
    lower_back: np.ndarray
    #: Left dorsal foot.
    left_foot: np.ndarray
    #: Right dorsal foot.
    right_foot: np.ndarray

    age: float | None
    gender: str | None
    bmi: float | None
    height_m: float | None
    weight_kg: float | None

    laterality: str | None
    clinical_deficit_side: str | None

    #: Name and value of the clinical evaluation score. For the ortho cohorts
    #: this is WOMAC on a 0-100 scale.
    evaluation_score_name: str | None
    evaluation_score_value: float | None

    visual_gait_assessment: float | None
    tug: str | None

    window_start: int
    window_end: int
    window_reason: str

    @property
    def window_samples(self) -> int:
        return max(0, self.window_end - self.window_start)

    @property
    def window_seconds(self) -> float:
        return self.window_samples / self.sample_rate_hz if self.sample_rate_hz else 0.0

    @property
    def is_ortho_target(self) -> bool:
        return COHORTS[self.cohort][2] is not None

    def windowed(self, sensor: np.ndarray) -> np.ndarray:
        return sensor[self.window_start : self.window_end]

    def to_meta_dict(self) -> dict:
        return {
            "trial_id": self.trial_id,
            "subject_id": self.subject_id,
            "cohort": self.cohort,
            "group": self.group,
            "pathology": self.pathology,
            "sample_rate_hz": self.sample_rate_hz,
            "age": self.age,
            "gender": self.gender,
            "bmi": self.bmi,
            "laterality": self.laterality,
            "clinical_deficit_side": self.clinical_deficit_side,
            "evaluation_score_name": self.evaluation_score_name,
            "evaluation_score_value": self.evaluation_score_value,
            "visual_gait_assessment": self.visual_gait_assessment,
            "window_start": self.window_start,
            "window_end": self.window_end,
            "window_samples": self.window_samples,
            "window_seconds": round(self.window_seconds, 3),
            "window_reason": self.window_reason,
        }


def iter_trial_dirs(
    cohorts: tuple[str, ...] = ("HS", "KOA", "HOA"),
) -> Iterator[tuple[str, pathlib.Path]]:
    """Yields ``(cohort, trial_dir)`` for the requested cohorts."""
    for cohort in cohorts:
        group = COHORTS[cohort][0]
        cohort_dir = DATASET_ROOT / group / cohort
        if not cohort_dir.is_dir():
            continue
        for subject_dir in sorted(p for p in cohort_dir.iterdir() if p.is_dir()):
            for trial_dir in sorted(p for p in subject_dir.iterdir() if p.is_dir()):
                yield cohort, trial_dir


def _load_processed(trial_dir: pathlib.Path) -> pd.DataFrame:
    processed = next(
        (p for p in trial_dir.iterdir() if p.name.endswith("_processed_data.txt")),
        None,
    )
    if processed is None:
        raise FileNotFoundError(f"no processed data in {trial_dir}")
    return pd.read_csv(processed, sep="\t")


def _sensor_block(df: pd.DataFrame, sensor: str) -> np.ndarray:
    """Extracts one sensor's 6 channels as [ax, ay, az, gx, gy, gz].

    Applies the unit conversion described in the module docstring:
    acceleration m/s^2 -> g, angular velocity rad/s -> deg/s.

    The magnetometer channels are deliberately dropped: the Motion Pod has no
    magnetometer, so a feature depending on them could never be reproduced on
    the device.
    """
    acc = np.column_stack(
        [
            df[f"{sensor}_Acc_X"].to_numpy(dtype=float),
            df[f"{sensor}_Acc_Y"].to_numpy(dtype=float),
            df[f"{sensor}_Acc_Z"].to_numpy(dtype=float),
        ]
    ) / MPS2_PER_G

    gyro = np.column_stack(
        [
            df[f"{sensor}_Gyr_X"].to_numpy(dtype=float),
            df[f"{sensor}_Gyr_Y"].to_numpy(dtype=float),
            df[f"{sensor}_Gyr_Z"].to_numpy(dtype=float),
        ]
    ) * RAD_S_TO_DEG_S

    return np.column_stack([acc, gyro])


def _walking_window(meta: dict, n_samples: int) -> tuple[int, int, str]:
    """Selects the steady-walking window used for feature extraction.

    Uses the contract in the metadata rather than eyeballing the signal:

    * Start at the first gait event (earliest heel-strike or toe-off across both
      feet), which skips the initial standing phase.
    * Stop at the u-turn, which excludes the turn and the return leg.

    A continuous single window is chosen deliberately. Concatenating the out and
    back legs would create a discontinuity that corrupts the phase-lag feature,
    which is a cross-correlation over the window.
    """
    uturn = meta.get("uturnBoundaries")
    left = meta.get("leftGaitEvents") or []
    right = meta.get("rightGaitEvents") or []
    events = list(left) + list(right)

    if uturn and len(uturn) == 2:
        uturn_start, _uturn_end = int(uturn[0]), int(uturn[1])
        if events:
            starts = [int(e[0]) for e in events if len(e) == 2]
            start = min(starts) if starts else 0
            end = min(uturn_start, n_samples)
            if end - start >= 100:
                return start, end, "first gait event to u-turn (steady walking)"
        return 0, min(uturn_start, n_samples), "trial start to u-turn"

    if events:
        starts = [int(e[0]) for e in events if len(e) == 2]
        ends = [int(e[1]) for e in events if len(e) == 2]
        start = max(0, min(starts))
        end = min(n_samples, max(ends))
        if end - start >= 100:
            return start, end, "first to last gait event"

    return 0, n_samples, "whole trial (no usable event annotations)"


def load_trial(cohort: str, trial_dir: pathlib.Path) -> TrialRecord:
    """Loads one trial with units normalised and the walking window applied."""
    meta = json.loads(next(trial_dir.glob("*_meta.json")).read_text(encoding="utf-8"))
    df = _load_processed(trial_dir)

    lower_back = _sensor_block(df, "LB")
    left_foot = _sensor_block(df, "LF")
    right_foot = _sensor_block(df, "RF")

    n = lower_back.shape[0]
    start, end, reason = _walking_window(meta, n)

    def number(key: str) -> float | None:
        value = meta.get(key)
        if isinstance(value, (int, float)):
            return float(value)
        return None

    return TrialRecord(
        trial_id=trial_dir.name,
        subject_id=meta.get("subject") or trial_dir.parent.name,
        cohort=cohort,
        group=meta.get("group") or COHORTS[cohort][0],
        pathology=meta.get("pathology"),
        sample_rate_hz=float(meta.get("freq") or 100.0),
        lower_back=lower_back,
        left_foot=left_foot,
        right_foot=right_foot,
        age=number("age"),
        gender=meta.get("gender"),
        bmi=number("BMI"),
        height_m=number("height"),
        weight_kg=number("weight"),
        laterality=meta.get("laterality"),
        clinical_deficit_side=meta.get("clinicalDeficitSide"),
        evaluation_score_name=meta.get("evaluationScoreName"),
        evaluation_score_value=number("evaluationScoreValue"),
        visual_gait_assessment=number("visualGaitAssessment"),
        tug=meta.get("TUG"),
        window_start=start,
        window_end=end,
        window_reason=reason,
    )


def load_cohort_trials(cohort: str, limit: int | None = None) -> list[TrialRecord]:
    records: list[TrialRecord] = []
    for _cohort, trial_dir in iter_trial_dirs((cohort,)):
        records.append(load_trial(cohort, trial_dir))
        if limit is not None and len(records) >= limit:
            break
    return records


def cohort_summary() -> pd.DataFrame:
    """One row per trial with the fields used for modelling and auditing."""
    rows = []
    for cohort, trial_dir in iter_trial_dirs(tuple(COHORTS)):
        meta = json.loads(next(trial_dir.glob("*_meta.json")).read_text(encoding="utf-8"))
        rows.append(
            {
                "cohort": cohort,
                "subject": meta.get("subject"),
                "trial": trial_dir.name,
                "age": meta.get("age"),
                "gender": meta.get("gender"),
                "bmi": meta.get("BMI"),
                "laterality": meta.get("laterality"),
                "deficit_side": meta.get("clinicalDeficitSide"),
                "score_name": meta.get("evaluationScoreName"),
                "score_value": meta.get("evaluationScoreValue"),
                "freq": meta.get("freq"),
            }
        )
    frame = pd.DataFrame(rows)
    # Coerce defensively: some trials carry a non-numeric placeholder (for
    # example the TUG field's "Not evaluated"), which would otherwise turn the
    # whole column into object dtype and silently break any numeric summary.
    for column in ("age", "bmi", "score_value", "freq"):
        if column in frame.columns:
            frame[column] = pd.to_numeric(frame[column], errors="coerce")
    return frame


def _main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Inspect the gait dataset.")
    parser.add_argument("--cohort", default=None, help="single cohort, e.g. KOA")
    args = parser.parse_args()

    if args.cohort:
        records = load_cohort_trials(args.cohort, limit=2)
        for record in records:
            lb = record.windowed(record.lower_back)
            mags = np.sqrt(np.sum(lb[:, 0:3] ** 2, axis=1))
            gyros = np.sqrt(np.sum(lb[:, 3:6] ** 2, axis=1))
            print(f"\n{record.trial_id}  ({record.subject_id})")
            print(f"  window   : {record.window_start}-{record.window_end} "
                  f"({record.window_seconds:.1f}s, {record.window_reason})")
            print(f"  age/sex  : {record.age} / {record.gender}   BMI {record.bmi}")
            print(f"  score    : {record.evaluation_score_name} = {record.evaluation_score_value}")
            print(f"  acc  (g) : mean {mags.mean():.3f} min {mags.min():.3f} max {mags.max():.3f}")
            print(f"  gyro(d/s): mean {gyros.mean():.2f} max {gyros.max():.2f}")
            print(f"  NaNs     : {int(np.isnan(lb).sum())} in lower back window")
        return 0

    summary = cohort_summary()
    print("\ntrials by cohort:")
    print(summary.groupby("cohort").size().to_string())
    print("\nsubjects by cohort:")
    print(summary.groupby("cohort")["subject"].nunique().to_string())

    print("\nevaluation score coverage (what each cohort is labelled with):")
    coverage = (
        summary.dropna(subset=["score_name"])
        .groupby(["cohort", "score_name"])
        .size()
        .rename("trials")
    )
    print(coverage.to_string())

    print("\northo score value ranges:")
    ortho = summary[summary["cohort"].isin(["KOA", "HOA", "ACL"])].dropna(
        subset=["score_value"]
    )
    if not ortho.empty:
        print(
            ortho.groupby("cohort")["score_value"]
            .describe()[["count", "mean", "std", "min", "max"]]
            .to_string()
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
