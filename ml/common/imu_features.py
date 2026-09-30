"""Canonical IMU feature definitions (PRD §15.1, §15.2).

WHY THIS FILE IS THE SOURCE OF TRUTH
------------------------------------
A model trained on features computed one way and served features computed
another way is a silent, total failure: the model still returns a confident
number, it is just meaningless. This class of bug is called train/serve skew and
it is the single most common way an on-device ML feature quietly breaks.

So the definitions live here, in one place, written as executable arithmetic:

    * ``ml/`` training reads these functions.
    * ``mobile/lib/wearable/imu_features.dart`` mirrors them line for line.
    * ``ml/common/parity.py`` emits a fixture of input traces and expected
      outputs, and ``mobile/test/wearable/parity_test.dart`` asserts the Dart
      mirror reproduces them to 1e-6.

If you change anything below, the Dart mirror must change with it, or the
parity test fails. That is intentional friction.

Every definition is stated explicitly rather than left to a library default,
because ``numpy.std`` defaults to ddof=0 while Dart's sample standard deviation
is ddof=1 — exactly the kind of discrepancy that would pass review and fail in
the field.

FEATURE DEFINITIONS
-------------------
With acceleration recorded in g and angular velocity in degrees/second:

    acc_mag[i]  = sqrt(ax^2 + ay^2 + az^2)
    gyro_mag[i] = sqrt(gx^2 + gy^2 + gz^2)

    imu_acc_magnitude_mean          = mean(acc_mag)
    imu_acc_magnitude_std           = sample std of acc_mag, ddof=1
    imu_acc_jerk_mean               = mean(|diff(acc_mag)|)
    imu_gyro_magnitude_mean         = mean(gyro_mag)
    imu_gyro_magnitude_peak         = max(gyro_mag)
    imu_gyro_hf_variance            = sample var (ddof=1) of the residual left
                                      after removing a centred moving average
                                      of window 5 from gyro_mag
    imu_proximal_distal_correlation = Pearson r between proximal and distal
                                      acc_mag over the window
    imu_relative_phase_lag          = lag in ms that maximises the
                                      cross-correlation between centred
                                      proximal and distal acc_mag
    imu_signal_quality              = fraction of samples whose acc_mag lies in
                                      [0.2, 8.0] g

Notes on the choices:

* ``imu_acc_magnitude_mean`` and friends use the Euclidean magnitude precisely
  because it is orientation-robust (PRD §15.2). PRD §15.2 also warns this does
  NOT make the whole signal placement-immune, and it does not: directional
  features and joint-angle estimates still depend on correct attachment.
* ``imu_acc_jerk_mean`` intentionally omits a sampling-rate term. It is a
  smoothness proxy, and keeping it rate-independent means a device that drops to
  40 Hz reports a comparable number instead of an artefactually lower one.
* ``imu_gyro_hf_variance`` is the crepitus/vibration exploration signal. PRD §15.3
  requires it to stay an *auxiliary* feature, so it is marked research-grade and
  excluded from the primary model.
* ``imu_signal_quality`` treats an exactly-zero sample as a dropout, which is how
  both the MPU-6050 driver and the BLE packet format encode "no reading".
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Sequence

import numpy as np

# ── tunables, mirrored in Dart ──────────────────────────────────────────────

#: Window (in samples) for the centred moving average used by the
#: high-frequency variance feature. Must be odd so the centre is unambiguous.
HF_MOVING_AVERAGE_WINDOW: int = 5

#: Plausible acceleration magnitude band, in g. Values outside this are treated
#: as unsaturating-but-invalid for the signal-quality ratio.
ACC_VALID_MIN_G: float = 0.2
ACC_VALID_MAX_G: float = 8.0

#: Maximum cross-correlation lag searched, in samples.
MAX_PHASE_LAG_SAMPLES: int = 200

#: Feature keys, in the exact order the exported model expects them.
#:
#: Order is part of the contract: the Dart side feeds a vector in this order, so
#: reordering this list without retraining would silently scramble the inputs.
FEATURE_ORDER: tuple[str, ...] = (
    "imu_acc_magnitude_mean",
    "imu_acc_magnitude_std",
    "imu_acc_jerk_mean",
    "imu_gyro_magnitude_mean",
    "imu_gyro_magnitude_peak",
    "imu_gyro_hf_variance",
    "imu_proximal_distal_correlation",
    "imu_relative_phase_lag",
    "imu_signal_quality",
)

#: Features that must never enter the primary model (PRD §13.4, §15.3).
RESEARCH_GRADE_FEATURES: frozenset[str] = frozenset(
    {
        "imu_gyro_hf_variance",
        "imu_relative_phase_lag",
    }
)


@dataclass(frozen=True)
class ImuTrial:
    """One recorded trial of six-axis IMU data.

    ``proximal`` and ``distal`` are arrays shaped (n, 6) with columns ordered
    ``[ax, ay, az, gx, gy, gz]``. Passing ``None`` for one pod is supported and
    represents the single-pod configuration; the two relative-motion features
    then report as unavailable rather than as zero.
    """

    sample_rate_hz: float
    proximal: np.ndarray | None = None
    distal: np.ndarray | None = None
    label: int | None = None
    participant_id: str | None = None
    metadata: dict = field(default_factory=dict)

    @property
    def n_samples(self) -> int:
        for arr in (self.proximal, self.distal):
            if arr is not None:
                return int(arr.shape[0])
        return 0

    def validate(self) -> None:
        for name, arr in (("proximal", self.proximal), ("distal", self.distal)):
            if arr is None:
                continue
            if arr.ndim != 2 or arr.shape[1] != 6:
                raise ValueError(
                    f"{name} must be shaped (n, 6) as [ax, ay, az, gx, gy, gz]; "
                    f"got {arr.shape}"
                )
        if self.proximal is None and self.distal is None:
            raise ValueError("at least one pod must be present")


# ── primitive definitions ───────────────────────────────────────────────────


def acc_magnitude(samples: np.ndarray) -> np.ndarray:
    """Euclidean acceleration magnitude in g (PRD §15.2)."""
    return np.sqrt(np.sum(np.square(samples[:, 0:3]), axis=1))


def gyro_magnitude(samples: np.ndarray) -> np.ndarray:
    """Euclidean angular velocity magnitude in deg/s."""
    return np.sqrt(np.sum(np.square(samples[:, 3:6]), axis=1))


def sample_std(values: np.ndarray) -> float:
    """Sample standard deviation with ddof=1, matching Dart.

    Returns 0 for fewer than two values instead of NaN, so a one-sample window
    degrades to "no variability observed" rather than poisoning a model input.
    """
    if values.size < 2:
        return 0.0
    return float(np.std(values, ddof=1))


def sample_var(values: np.ndarray) -> float:
    """Sample variance with ddof=1, matching Dart."""
    if values.size < 2:
        return 0.0
    return float(np.var(values, ddof=1))


def mean_abs_diff(values: np.ndarray) -> float:
    """Mean absolute first difference. Rate-independent smoothness proxy."""
    if values.size < 2:
        return 0.0
    return float(np.mean(np.abs(np.diff(values))))


def centred_moving_average(values: np.ndarray, window: int) -> np.ndarray:
    """Centred moving average with shrinking windows at the edges.

    Edge behaviour is defined explicitly (average whatever samples exist within
    the window, rather than padding with zeros or dropping the edges) because
    this is exactly the kind of detail that differs between two implementations
    and breaks parity.
    """
    if window < 1:
        raise ValueError("window must be >= 1")
    radius = window // 2
    n = values.size
    out = np.empty(n, dtype=float)
    for i in range(n):
        lo = max(0, i - radius)
        hi = min(n, i + radius + 1)
        out[i] = float(np.mean(values[lo:hi]))
    return out


def pearson_r(a: np.ndarray, b: np.ndarray) -> float:
    """Pearson correlation, 0 when either input has no variance."""
    if a.size < 2 or b.size < 2 or a.size != b.size:
        return 0.0
    a_centred = a - float(np.mean(a))
    b_centred = b - float(np.mean(b))
    denom = float(np.sqrt(np.sum(a_centred**2) * np.sum(b_centred**2)))
    if denom == 0:
        return 0.0
    return float(np.sum(a_centred * b_centred) / denom)


def best_phase_lag_samples(
    proximal: np.ndarray,
    distal: np.ndarray,
    max_lag: int = MAX_PHASE_LAG_SAMPLES,
) -> int:
    """Lag, in samples, that maximises cross-correlation of the two signals.

    Positive means the distal signal trails the proximal one. Ties resolve to
    the smaller absolute lag, then to the negative lag, so the result is
    deterministic and reproducible across implementations.
    """
    n = min(proximal.size, distal.size)
    if n < 3:
        return 0
    limit = min(max_lag, n // 2)
    if limit < 1:
        return 0

    a = proximal[:n] - float(np.mean(proximal[:n]))
    b = distal[:n] - float(np.mean(distal[:n]))

    # Search order: 0, -1, +1, -2, +2, ...
    # Combined with a strict ">" comparison this makes the tie-break explicit
    # and trivial to mirror: the first maximum encountered wins, which prefers
    # the smallest absolute lag and, at equal magnitude, the negative lag. The
    # ordering and the comparison are both mirrored in Dart so the two
    # implementations cannot disagree on a tie.
    order = [0]
    for k in range(1, limit + 1):
        order.append(-k)
        order.append(k)

    best_lag = 0
    best_score = -np.inf
    for lag in order:
        if lag >= 0:
            x, y = a[: n - lag], b[lag:]
        else:
            x, y = a[-lag:], b[: n + lag]
        if x.size < 3:
            continue
        score = float(np.sum(x * y))
        if score > best_score:
            best_score = score
            best_lag = lag
    return best_lag


def signal_quality(samples: np.ndarray) -> float:
    """Fraction of samples with a plausible acceleration magnitude.

    Non-finite samples count as invalid, as does an exactly-zero reading (how a
    dropout is encoded) or a saturated one.
    """
    if samples.shape[0] == 0:
        return 0.0
    mags = acc_magnitude(samples)
    valid = np.isfinite(mags) & (mags >= ACC_VALID_MIN_G) & (mags <= ACC_VALID_MAX_G)
    return float(np.count_nonzero(valid) / mags.size)


# ── the feature vector ──────────────────────────────────────────────────────


def extract_features(trial: ImuTrial) -> dict[str, float]:
    """Computes the feature vector for one trial.

    Only features that can actually be computed appear in the result. The two
    relative-motion features need two pods, so with a single pod they are absent
    rather than zero — an absent feature must not be silently read as "no
    proximal-distal coupling", which would be a fabricated measurement.
    """
    trial.validate()

    features: dict[str, float] = {}

    reference = trial.proximal if trial.proximal is not None else trial.distal
    assert reference is not None

    mags = acc_magnitude(reference)
    gyros = gyro_magnitude(reference)

    features["imu_acc_magnitude_mean"] = float(np.mean(mags))
    features["imu_acc_magnitude_std"] = sample_std(mags)
    features["imu_acc_jerk_mean"] = mean_abs_diff(mags)
    features["imu_gyro_magnitude_mean"] = float(np.mean(gyros))
    features["imu_gyro_magnitude_peak"] = float(np.max(gyros))

    smoothed = centred_moving_average(gyros, HF_MOVING_AVERAGE_WINDOW)
    features["imu_gyro_hf_variance"] = sample_var(gyros - smoothed)

    features["imu_signal_quality"] = signal_quality(reference)

    if trial.proximal is not None and trial.distal is not None:
        prox = acc_magnitude(trial.proximal)
        dist = acc_magnitude(trial.distal)
        features["imu_proximal_distal_correlation"] = pearson_r(prox, dist)
        features["imu_relative_phase_lag"] = (
            best_phase_lag_samples(prox, dist) / trial.sample_rate_hz * 1000.0
        )

    return features


def feature_vector(
    trial: ImuTrial,
    keys: Sequence[str] = FEATURE_ORDER,
) -> np.ndarray:
    """Feature vector in a fixed, caller-declared key order.

    Raises on a missing key rather than substituting a default: the whole point
    of a fixed order is that a mismatch must be loud.
    """
    feats = extract_features(trial)
    missing = [k for k in keys if k not in feats]
    if missing:
        raise KeyError(f"features unavailable for this trial: {missing}")
    return np.asarray([feats[k] for k in keys], dtype=np.float64)


def available_feature_keys(trial: ImuTrial) -> list[str]:
    """Feature keys computable for this trial, in canonical order."""
    feats = extract_features(trial)
    return [k for k in FEATURE_ORDER if k in feats]
