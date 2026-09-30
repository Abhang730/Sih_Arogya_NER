"""Train/serve parity harness.

Writes a fixture of input traces and the features this Python implementation
computes for them. ``mobile/test/wearable/imu_parity_test.dart`` runs the Dart
mirror over the same inputs and asserts it produces the same numbers.

Without this, a model trained here could be served subtly different features on
the device and still return confident, meaningless output. That failure is
invisible in production and invisible in the training metrics — the only place
it can be caught is a shared fixture like this one.

Run::

    python ml/common/parity.py
"""

from __future__ import annotations

import json
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent))

from ml.common.imu_features import (  # noqa: E402
    FEATURE_ORDER,
    ImuTrial,
    extract_features,
)

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
FIXTURE_PATH = ROOT / "mobile" / "test" / "fixtures" / "imu_feature_parity.json"

#: Compared with this tolerance. Float summation order differs between numpy and
#: Dart, so exact equality is not achievable; 1e-9 is tight enough to catch any
#: real algorithmic difference (a wrong ddof changes the third decimal, a wrong
#: window changes the second).
TOLERANCE = 1e-9


def _sinusoidal_gait_trial(seed: int, n: int = 300, fs: float = 100.0) -> dict:
    """A synthetic two-pod walking trace with a known phase relationship."""
    rng = np.random.default_rng(seed)
    t = np.arange(n) / fs

    def pod(phase: float, amplitude: float) -> np.ndarray:
        ax = amplitude * np.sin(2 * np.pi * 1.1 * t + phase)
        ay = 0.35 * amplitude * np.cos(2 * np.pi * 1.1 * t + phase)
        az = 1.0 + 0.25 * amplitude * np.sin(2 * np.pi * 2.2 * t + phase)
        gx = 40.0 * np.sin(2 * np.pi * 1.1 * t + phase)
        gy = 18.0 * np.cos(2 * np.pi * 1.1 * t + phase)
        gz = 6.0 * np.sin(2 * np.pi * 0.55 * t + phase)
        noise = rng.normal(0, 0.01, size=(n, 6))
        return np.column_stack([ax, ay, az, gx, gy, gz]) + noise

    return {
        "name": "sinusoidal_two_pod",
        "description": "Synthetic 1.1 Hz gait, two pods, 100 Hz, 3 seconds.",
        "sample_rate_hz": fs,
        "proximal": pod(0.0, 0.8).tolist(),
        "distal": pod(0.35, 0.6).tolist(),
    }


def _single_pod_trial(seed: int, n: int = 200, fs: float = 50.0) -> dict:
    """A single-pod trace, so relative-motion features must be absent."""
    rng = np.random.default_rng(seed)
    t = np.arange(n) / fs
    data = np.column_stack(
        [
            0.5 * np.sin(2 * np.pi * 1.5 * t),
            0.3 * np.cos(2 * np.pi * 1.5 * t),
            1.0 + 0.2 * np.sin(2 * np.pi * 3.0 * t),
            25.0 * np.sin(2 * np.pi * 1.5 * t),
            10.0 * np.cos(2 * np.pi * 1.5 * t),
            4.0 * np.sin(2 * np.pi * 0.75 * t),
        ]
    ) + rng.normal(0, 0.02, size=(n, 6))
    return {
        "name": "single_pod",
        "description": "Single-pod trace at 50 Hz. Relative features must be absent.",
        "sample_rate_hz": fs,
        "proximal": data.tolist(),
        "distal": None,
    }


def _static_trial(n: int = 120, fs: float = 50.0) -> dict:
    """A perfectly still trace. Every variability feature must be exactly zero."""
    data = np.zeros((n, 6))
    data[:, 2] = 1.0  # gravity only
    return {
        "name": "static_zero_variance",
        "description": "Motionless trace. Variability features must be exactly 0.",
        "sample_rate_hz": fs,
        "proximal": data.tolist(),
        "distal": data.tolist(),
    }


def _dropout_trial(n: int = 150, fs: float = 50.0) -> dict:
    """A trace containing dropouts and saturation, to exercise signal quality."""
    data = np.zeros((n, 6))
    data[:, 2] = 1.0
    data[10:20, :3] = 0.0        # encoded dropouts
    data[40:45, 2] = 25.0        # saturated
    data[60:70, 0] = 0.9         # normal movement
    return {
        "name": "with_dropouts_and_saturation",
        "description": "Contains 10 dropout samples and 5 saturated samples.",
        "sample_rate_hz": fs,
        "proximal": data.tolist(),
        "distal": None,
    }


def _short_trial() -> dict:
    """Below the minimum length for most statistics."""
    return {
        "name": "too_short",
        "description": "Two samples only. Must degrade to zeros, not NaN.",
        "sample_rate_hz": 50.0,
        "proximal": [[0.0, 0.0, 1.0, 0.0, 0.0, 0.0], [0.01, 0.0, 1.0, 1.0, 0.0, 0.0]],
        "distal": None,
    }


def build_fixture() -> dict:
    cases = [
        _sinusoidal_gait_trial(seed=1234),
        _single_pod_trial(seed=99),
        _static_trial(),
        _dropout_trial(),
        _short_trial(),
    ]

    cases_out = []
    for case in cases:
        trial = ImuTrial(
            sample_rate_hz=case["sample_rate_hz"],
            proximal=None if case["proximal"] is None else np.asarray(case["proximal"]),
            distal=None if case["distal"] is None else np.asarray(case["distal"]),
        )
        features = extract_features(trial)

        # Fail loudly here rather than shipping a NaN into a model input.
        for key, value in features.items():
            if not np.isfinite(value):
                raise ValueError(f"{case['name']}: feature {key} is not finite ({value})")

        cases_out.append(
            {
                **case,
                "expected": {k: v for k, v in features.items()},
                # Explicitly records which features are EXPECTED to be absent, so
                # the Dart side can assert absence rather than only comparing
                # the values that happen to be present.
                "expected_absent": [k for k in FEATURE_ORDER if k not in features],
            }
        )

    return {
        "generated_by": "ml/common/parity.py",
        "source_of_truth": "ml/common/imu_features.py",
        "mirror_under_test": "mobile/lib/wearable/imu_features.dart",
        "tolerance": TOLERANCE,
        "purpose": (
            "Pins Python (training) and Dart (on-device inference) IMU feature "
            "extraction to identical outputs. Any divergence means the model is "
            "served features it was not trained on."
        ),
        "feature_order": list(FEATURE_ORDER),
        "cases": cases_out,
    }


def main() -> int:
    fixture = build_fixture()
    FIXTURE_PATH.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE_PATH.write_text(json.dumps(fixture, indent=1), encoding="utf-8")

    print(f"wrote {FIXTURE_PATH.relative_to(ROOT)}")
    for case in fixture["cases"]:
        present = len(case["expected"])
        absent = len(case["expected_absent"])
        print(
            f"  {case['name']:<32} {present} features, {absent} expected absent"
        )
    print(f"tolerance: {fixture['tolerance']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
