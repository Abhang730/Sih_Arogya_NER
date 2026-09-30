// On-device IMU feature extraction.
//
// THIS FILE IS A MIRROR of ml/common/imu_features.py. That Python module is the
// source of truth, because it is what the training pipeline reads. This file
// must reproduce its arithmetic exactly, or the trained model will be served
// features that mean something different from what it learned on.
//
// Train/serve skew is silent: the model still returns a confident number, it is
// just meaningless. So the two implementations are held together by a generated
// fixture — ml/common/parity.py writes ml/fixtures/imu_feature_parity.json, and
// mobile/test/wearable/imu_parity_test.dart asserts this file reproduces it to
// 1e-6. If you change an algorithm here, change it there too or the test fails.
//
// Note the deliberate choice to reimplement rather than approximate: numpy's
// default std uses ddof=0, Dart's sample standard deviation uses ddof=1. Getting
// that wrong produces a subtle, permanent bias in every model input.

import 'dart:math' as math;

/// One six-axis sample: `[ax, ay, az, gx, gy, gz]`.
///
/// Acceleration in g, angular velocity in degrees/second.
typedef ImuSample = List<double>;

/// Window (in samples) for the centred moving average used by the
/// high-frequency variance feature. Mirrors HF_MOVING_AVERAGE_WINDOW.
const int hfMovingAverageWindow = 5;

/// Plausible acceleration magnitude band, in g. Mirrors ACC_VALID_MIN/MAX_G.
const double accValidMinG = 0.2;
const double accValidMaxG = 8.0;

/// Maximum cross-correlation lag searched, in samples. Mirrors
/// MAX_PHASE_LAG_SAMPLES.
const int maxPhaseLagSamples = 200;

/// Feature keys in the exact order an exported model expects them.
///
/// Order is part of the contract. Reordering this without retraining would
/// silently scramble every input to the model, so the exported manifest records
/// the order it was trained with and TfliteBranch feeds the vector in that
/// order rather than this one.
const List<String> imuFeatureOrder = [
  'imu_acc_magnitude_mean',
  'imu_acc_magnitude_std',
  'imu_acc_jerk_mean',
  'imu_gyro_magnitude_mean',
  'imu_gyro_magnitude_peak',
  'imu_gyro_hf_variance',
  'imu_proximal_distal_correlation',
  'imu_relative_phase_lag',
  'imu_signal_quality',
];

/// Features that must never enter the primary model (PRD §13.4, §15.3).
const Set<String> researchGradeImuFeatures = {
  'imu_gyro_hf_variance',
  'imu_relative_phase_lag',
};

/// One recorded trial. Either pod may be absent, which represents the
/// single-pod configuration.
class ImuTrial {
  const ImuTrial({
    required this.sampleRateHz,
    this.proximal,
    this.distal,
    this.label,
    this.participantId,
  });

  final double sampleRateHz;
  final List<ImuSample>? proximal;
  final List<ImuSample>? distal;
  final int? label;
  final String? participantId;

  int get sampleCount => proximal?.length ?? distal?.length ?? 0;

  /// Throws on a malformed trial rather than coercing it. A trial shaped
  /// wrongly would otherwise produce plausible-looking garbage.
  void validate() {
    for (final entry in {'proximal': proximal, 'distal': distal}.entries) {
      final samples = entry.value;
      if (samples == null) continue;
      for (final sample in samples) {
        if (sample.length != 6) {
          throw ArgumentError(
            'imu_features: ${entry.key} samples must have 6 channels '
            '[ax, ay, az, gx, gy, gz]; found ${sample.length}',
          );
        }
      }
    }
    if (proximal == null && distal == null) {
      throw ArgumentError('imu_features: at least one pod must be present');
    }
  }
}

// ── primitive definitions (mirroring the Python) ────────────────────────────

/// Euclidean acceleration magnitude in g (PRD §15.2).
List<double> accMagnitude(List<ImuSample> samples) => samples
    .map((s) => math.sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]))
    .toList(growable: false);

/// Euclidean angular velocity magnitude in deg/s.
List<double> gyroMagnitude(List<ImuSample> samples) => samples
    .map((s) => math.sqrt(s[3] * s[3] + s[4] * s[4] + s[5] * s[5]))
    .toList(growable: false);

/// Sample standard deviation with ddof=1, matching the Python.
///
/// Returns 0 for fewer than two values rather than NaN, so a short window
/// degrades to "no variability observed" instead of poisoning a model input.
double sampleStd(List<double> values) {
  if (values.length < 2) return 0;
  final mean = values.reduce((a, b) => a + b) / values.length;
  var sumSq = 0.0;
  for (final v in values) {
    final d = v - mean;
    sumSq += d * d;
  }
  return math.sqrt(sumSq / (values.length - 1));
}

/// Sample variance with ddof=1, matching the Python.
double sampleVar(List<double> values) {
  if (values.length < 2) return 0;
  final mean = values.reduce((a, b) => a + b) / values.length;
  var sumSq = 0.0;
  for (final v in values) {
    final d = v - mean;
    sumSq += d * d;
  }
  return sumSq / (values.length - 1);
}

/// Mean absolute first difference. Rate-independent smoothness proxy.
double meanAbsDiff(List<double> values) {
  if (values.length < 2) return 0;
  var sum = 0.0;
  for (var i = 1; i < values.length; i++) {
    sum += (values[i] - values[i - 1]).abs();
  }
  return sum / (values.length - 1);
}

/// Centred moving average with shrinking windows at the edges.
///
/// The edge rule is defined explicitly (average whatever samples exist within
/// the window) rather than left implicit, because edge behaviour is exactly
/// where two implementations usually diverge and break parity.
List<double> centredMovingAverage(List<double> values, int window) {
  if (window < 1) throw ArgumentError('window must be >= 1');
  final radius = window ~/ 2;
  final n = values.length;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - radius);
    final hi = math.min(n, i + radius + 1);
    var sum = 0.0;
    for (var j = lo; j < hi; j++) {
      sum += values[j];
    }
    out[i] = sum / (hi - lo);
  }
  return out;
}

/// Pearson correlation, 0 when either input has no variance.
double pearsonR(List<double> a, List<double> b) {
  if (a.length < 2 || b.length < 2 || a.length != b.length) return 0;
  final meanA = a.reduce((x, y) => x + y) / a.length;
  final meanB = b.reduce((x, y) => x + y) / b.length;

  var sumAB = 0.0;
  var sumAA = 0.0;
  var sumBB = 0.0;
  for (var i = 0; i < a.length; i++) {
    final da = a[i] - meanA;
    final db = b[i] - meanB;
    sumAB += da * db;
    sumAA += da * da;
    sumBB += db * db;
  }
  final denom = math.sqrt(sumAA * sumBB);
  if (denom == 0) return 0;
  return sumAB / denom;
}

/// Lag, in samples, that maximises the cross-correlation of the two signals.
///
/// Positive means the distal signal trails the proximal one. The search order is
/// 0, -1, +1, -2, +2, ... combined with a strict comparison, which makes the
/// tie-break explicit and directly mirrorable: the first maximum encountered
/// wins, preferring the smallest absolute lag and, at equal magnitude, the
/// negative lag.
int bestPhaseLagSamples(
  List<double> proximal,
  List<double> distal, {
  int maxLag = maxPhaseLagSamples,
}) {
  final n = math.min(proximal.length, distal.length);
  if (n < 3) return 0;
  final limit = math.min(maxLag, n ~/ 2);
  if (limit < 1) return 0;

  final meanA = proximal.take(n).reduce((a, b) => a + b) / n;
  final meanB = distal.take(n).reduce((a, b) => a + b) / n;
  final a = List<double>.generate(n, (i) => proximal[i] - meanA, growable: false);
  final b = List<double>.generate(n, (i) => distal[i] - meanB, growable: false);

  final order = <int>[0];
  for (var k = 1; k <= limit; k++) {
    order.add(-k);
    order.add(k);
  }

  var bestLag = 0;
  var bestScore = double.negativeInfinity;

  for (final lag in order) {
    final int xStart;
    final int yStart;
    final int length;
    if (lag >= 0) {
      xStart = 0;
      yStart = lag;
      length = n - lag;
    } else {
      xStart = -lag;
      yStart = 0;
      length = n + lag;
    }
    if (length < 3) continue;

    var score = 0.0;
    for (var i = 0; i < length; i++) {
      score += a[xStart + i] * b[yStart + i];
    }
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }
  return bestLag;
}

/// Fraction of samples with a plausible acceleration magnitude.
///
/// Non-finite samples count as invalid, as does an exactly-zero reading (how a
/// dropout is encoded) or a saturated one.
double signalQuality(List<ImuSample> samples) {
  if (samples.isEmpty) return 0;
  final mags = accMagnitude(samples);
  var valid = 0;
  for (final m in mags) {
    if (m.isFinite && m >= accValidMinG && m <= accValidMaxG) valid++;
  }
  return valid / mags.length;
}

// ── the feature vector ─────────────────────────────────────────────────────

/// Computes the feature vector for one trial.
///
/// Only features that can actually be computed appear in the result. The two
/// relative-motion features need two pods, so with a single pod they are ABSENT
/// rather than zero: an absent feature must never be silently read as "no
/// proximal-distal coupling", which would be a fabricated measurement.
Map<String, double> extractImuFeatures(ImuTrial trial) {
  trial.validate();

  final features = <String, double>{};
  final reference = trial.proximal ?? trial.distal!;

  final mags = accMagnitude(reference);
  final gyros = gyroMagnitude(reference);

  features['imu_acc_magnitude_mean'] = mags.reduce((a, b) => a + b) / mags.length;
  features['imu_acc_magnitude_std'] = sampleStd(mags);
  features['imu_acc_jerk_mean'] = meanAbsDiff(mags);
  features['imu_gyro_magnitude_mean'] = gyros.reduce((a, b) => a + b) / gyros.length;
  features['imu_gyro_magnitude_peak'] = gyros.reduce(math.max);

  final smoothed = centredMovingAverage(gyros, hfMovingAverageWindow);
  features['imu_gyro_hf_variance'] = sampleVar(
    List<double>.generate(gyros.length, (i) => gyros[i] - smoothed[i], growable: false),
  );

  features['imu_signal_quality'] = signalQuality(reference);

  final proximal = trial.proximal;
  final distal = trial.distal;
  if (proximal != null && distal != null) {
    final prox = accMagnitude(proximal);
    final dist = accMagnitude(distal);
    features['imu_proximal_distal_correlation'] = pearsonR(prox, dist);
    features['imu_relative_phase_lag'] =
        bestPhaseLagSamples(prox, dist) / trial.sampleRateHz * 1000.0;
  }

  return features;
}

/// Feature vector in a caller-declared key order.
///
/// Throws on a missing key rather than substituting a default: the whole point
/// of a fixed order is that a mismatch must be loud.
List<double> imuFeatureVector(
  ImuTrial trial, {
  List<String> keys = imuFeatureOrder,
}) {
  final features = extractImuFeatures(trial);
  final missing = keys.where((k) => !features.containsKey(k)).toList(growable: false);
  if (missing.isNotEmpty) {
    throw StateError('imu_features: features unavailable for this trial: $missing');
  }
  return keys.map((k) => features[k]!).toList(growable: false);
}
