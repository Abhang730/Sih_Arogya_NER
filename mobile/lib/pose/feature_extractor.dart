// Feature extraction (PRD §9.5, §13.3, §15).
//
// This converts landmark sequences into the features the protocol declares. Two
// principles drive the implementation:
//
// 1. These are MEASUREMENTS, not OA probabilities. A knee flexion range of 112
//    degrees is a fact about the capture; whether it implies osteoarthritis is
//    a separate, model-level question the PRD keeps explicitly separate
//    (§6.2, §26.3).
// 2. A feature that cannot be computed is REPORTED AS MISSING, never defaulted
//    to zero. A zero-filled feature silently becomes a false measurement and
//    would flow straight into fusion as if it were real (PRD §1.2, §15.4).
//
// Everything here is 2D, image-plane geometry. Monocular pose has no metric
// depth, so angles are view-dependent: a knee measured from the side view is
// meaningful, the same knee measured from the front is not. Protocols declare
// the intended camera view per test, and the extractor records the view used so
// a specialist can judge whether a number is interpretable (PRD §13.4).

import 'dart:math' as math;

import '../core/stats.dart';
import '../domain/protocol/models.dart';
import 'pose_types.dart';

/// Outcome of extracting features for one movement test.
class FeatureExtractionResult {
  const FeatureExtractionResult({
    required this.testId,
    required this.features,
    required this.series,
    required this.missingFeatures,
    required this.frameCount,
    required this.confidence,
    required this.notes,
  });

  final String testId;

  /// Named measurements that were successfully computed.
  final Map<String, double> features;

  /// Time series retained for the dashboard's movement view (PRD §23.1).
  final Map<String, List<double>> series;

  /// Protocol-declared features this capture could not produce. Surfaced to the
  /// worker and the specialist rather than hidden.
  final List<String> missingFeatures;

  final int frameCount;

  /// 0..1 confidence for this test, derived from landmark likelihood and
  /// coverage. Consumed by confidence-aware fusion (PRD §15.4, §17.5).
  final double confidence;

  final List<String> notes;

  bool get hasUsableData => features.isNotEmpty;

  double? operator [](String key) => features[key];

  Map<String, dynamic> toJson() => {
        'test_id': testId,
        'features': features,
        'series_lengths': {
          for (final e in series.entries) e.key: e.value.length,
        },
        'missing_features': missingFeatures,
        'frame_count': frameCount,
        'confidence': confidence,
        'notes': notes,
      };
}

/// Computes the protocol's declared features from pose frames.
class FeatureExtractor {
  FeatureExtractor({required this.topology, required this.protocol});

  final LandmarkTopology topology;
  final JointProtocol protocol;

  /// Minimum likelihood for a landmark to contribute to an angle. Below this the
  /// frame is skipped rather than contributing a noisy angle that would widen
  /// the apparent range of motion.
  static const double minLandmarkLikelihood = 0.4;

  FeatureExtractionResult extract({
    required MovementTest test,
    required List<PoseFrame> frames,
  }) {
    final notes = <String>[];
    final missing = <String>[];

    if (frames.length < 2) {
      return FeatureExtractionResult(
        testId: test.id,
        features: const {},
        series: const {},
        missingFeatures: test.derivedFeatures,
        frameCount: frames.length,
        confidence: 0,
        notes: const ['Not enough frames captured for this test.'],
      );
    }

    final usable = frames.where((f) => f.meanLikelihood >= minLandmarkLikelihood).toList();
    if (usable.length < 2) {
      return FeatureExtractionResult(
        testId: test.id,
        features: const {},
        series: const {},
        missingFeatures: test.derivedFeatures,
        frameCount: frames.length,
        confidence: 0,
        notes: const [
          'Pose confidence was too low across the whole capture to measure anything.',
        ],
      );
    }
    if (usable.length < frames.length) {
      notes.add('${frames.length - usable.length} of ${frames.length} frames were '
          'discarded for low pose confidence.');
    }

    // ── per-frame joint angle series, one per declared chain ─────────────
    final indexByKey = topology.indexByKey;
    final angleSeries = <String, List<double>>{};
    final timeSeries = <double>[];
    final kneeKeys = <String, List<double>>{};

    for (final chain in protocol.landmarks.jointChains) {
      angleSeries[chain.angleFeature] = <double>[];
    }
    for (final key in ['left_knee', 'right_knee']) {
      kneeKeys[key] = <double>[];
    }

    for (final frame in usable) {
      timeSeries.add(frame.seconds);
      for (final chain in protocol.landmarks.jointChains) {
        final angle = _chainFlexion(frame, indexByKey, chain.landmarks);
        if (angle != null) {
          angleSeries[chain.angleFeature]!.add(angle);
        }
      }
    }

    final context = _ExtractionContext(
      topology: topology,
      protocol: protocol,
      usableFrames: usable,
      allFrames: frames,
      angleSeries: angleSeries,
      timeSeries: timeSeries,
      indexByKey: indexByKey,
      notes: notes,
    );

    // ── the protocol's declared features ─────────────────────────────────
    final features = <String, double>{};
    for (final key in test.derivedFeatures) {
      final value = _compute(key, context, test);
      if (value == null || value.isNaN || value.isInfinite) {
        missing.add(key);
      } else {
        features[key] = value;
      }
    }

    if (missing.isNotEmpty) {
      notes.add('Could not measure: ${missing.join(', ')}. These are reported '
          'as unavailable rather than estimated.');
    }

    return FeatureExtractionResult(
      testId: test.id,
      features: features,
      series: angleSeries.map(
        (k, v) => MapEntry(k, List<double>.unmodifiable(v)),
      ),
      missingFeatures: missing,
      frameCount: usable.length,
      confidence: _confidence(usable),
      notes: notes,
    );
  }

  // ─────────────────────────────────────────────── geometry primitives ──

  /// Joint flexion in degrees at [b], from the chain a-b-c.
  ///
  /// Returns the *flexion* angle: 0 means the limb is fully straight (a-b-c
  /// collinear) and larger values mean the joint is increasingly bent. That is
  /// the convention the protocol's `_min` / `_max` / `_rom` features assume,
  /// and it is the one clinicians read naturally.
  static double? _chainFlexion(
    PoseFrame frame,
    Map<String, int> indexByKey,
    List<String> keys,
  ) {
    if (keys.length < 3) return null;
    final a = frame.landmark(indexByKey, keys[0]);
    final b = frame.landmark(indexByKey, keys[1]);
    final c = frame.landmark(indexByKey, keys[2]);
    if (a == null || b == null || c == null) return null;
    if (a.likelihood < minLandmarkLikelihood ||
        b.likelihood < minLandmarkLikelihood ||
        c.likelihood < minLandmarkLikelihood) {
      return null;
    }
    return flexionAngleDegrees(a.x, a.y, b.x, b.y, c.x, c.y);
  }

  /// Included angle at (bx,by) between (ax,ay) and (cx,cy), converted to a
  /// flexion angle in degrees in [0,180].
  static double flexionAngleDegrees(
    double ax,
    double ay,
    double bx,
    double by,
    double cx,
    double cy,
  ) {
    final v1x = ax - bx;
    final v1y = ay - by;
    final v2x = cx - bx;
    final v2y = cy - by;

    final n1 = math.sqrt(v1x * v1x + v1y * v1y);
    final n2 = math.sqrt(v2x * v2x + v2y * v2y);
    if (n1 == 0 || n2 == 0) return 0;

    final cosTheta = ((v1x * v2x + v1y * v2y) / (n1 * n2)).clamp(-1.0, 1.0);
    final included = math.acos(cosTheta) * 180.0 / math.pi;
    return (180.0 - included).clamp(0.0, 180.0).toDouble();
  }

  /// Lean of the b->c segment from vertical, in degrees.
  static double leanFromVerticalDegrees(double bx, double by, double cx, double cy) {
    final dx = cx - bx;
    final dy = cy - by;
    if (dx == 0 && dy == 0) return 0;
    return math.atan2(dx.abs(), dy.abs()) * 180.0 / math.pi;
  }

  // ─────────────────────────────────────────────────── feature factory ──

  double? _compute(String key, _ExtractionContext ctx, MovementTest test) {
    // Fall back to the left side when there is no right chain, so a protocol
    // that only declares one side still extracts what it can.
    final kneeSeries = ctx.angleSeries['knee_flexion_angle_right'] ??
        ctx.angleSeries['knee_flexion_angle_left'];

    switch (key) {
      // ── active range of motion ────────────────────────────────────────
      case 'knee_flexion_angle_min':
        return kneeSeries == null || kneeSeries.isEmpty ? null : Stats.min(kneeSeries);
      case 'knee_flexion_angle_max':
        return kneeSeries == null || kneeSeries.isEmpty ? null : Stats.max(kneeSeries);
      case 'knee_flexion_rom':
        final s = ctx.angleSeries['knee_flexion_angle_right'];
        return s == null || s.length < 2 ? null : Stats.range(s);
      case 'hip_flexion_rom':
        final s = ctx.angleSeries['hip_flexion_angle_right'];
        return s == null || s.length < 2 ? null : Stats.range(s);
      case 'shoulder_flexion_rom':
      case 'shoulder_abduction_rom':
        final s = ctx.angleSeries['shoulder_flexion_angle_right'];
        return s == null || s.length < 2 ? null : Stats.range(s);
      case 'knee_extension_deficit':
        // Shortfall from full extension, i.e. the smallest flexion angle
        // reached. A knee that cannot reach 0 is reporting its deficit.
        final s = ctx.angleSeries['knee_flexion_angle_right'];
        return s == null || s.isEmpty ? null : Stats.min(s);
      case 'elbow_flexion_rom':
        final s = ctx.angleSeries['elbow_flexion_angle_right'];
        return s == null || s.length < 2 ? null : Stats.range(s);
      case 'elbow_extension_deficit':
        final s = ctx.angleSeries['elbow_flexion_angle_right'];
        return s == null || s.isEmpty ? null : Stats.min(s);
      case 'ankle_dorsiflexion_rom':
      case 'ankle_plantarflexion_rom':
        final s = ctx.angleSeries['ankle_dorsiflexion_angle_right'];
        return s == null || s.length < 2 ? null : Stats.range(s);
      case 'wrist_flexion_rom':
      case 'wrist_extension_rom':
        final s = ctx.angleSeries['wrist_angle_right'];
        return s == null || s.length < 2 ? null : Stats.range(s);

      // ── angular velocity / movement quality ───────────────────────────
      case 'knee_angular_velocity_peak':
        final s = ctx.angleSeries['knee_flexion_angle_right'] ?? kneeSeries;
        return s == null || s.length < 3 ? null : ctx.degreePerSecond(s);
      case 'elbow_rotation_proxy':
        return null; // needs hand-landmark orientation that 2D pose cannot give reliably

      // ── sit-to-stand ──────────────────────────────────────────────────
      case 'sts_duration_mean':
        final d = ctx.sitToStandDurations();
        return d.isEmpty ? null : Stats.mean(d);
      case 'sts_duration_cv':
        final d = ctx.sitToStandDurations();
        return d.length < 2 ? null : Stats.cv(d);
      case 'sts_knee_angle_min':
        final knee = kneeSeries ?? ctx.angleSeries['knee_flexion_angle_left'];
        return knee == null || knee.isEmpty ? null : Stats.min(knee);
      case 'sts_symmetry_index':
        return ctx.kneeSymmetryIndex();
      case 'sts_trunk_flexion_peak':
        return ctx.trunkThighRange();

      // ── gait ──────────────────────────────────────────────────────────
      case 'gait_cadence':
        final stepTimes = ctx.stepTimes();
        if (stepTimes.isEmpty) return null;
        final mean = Stats.mean(stepTimes);
        return mean <= 0 ? null : 60.0 / mean;
      case 'gait_step_time_mean':
        final stepTimes = ctx.stepTimes();
        return stepTimes.isEmpty ? null : Stats.mean(stepTimes);
      case 'gait_step_time_cv':
        final stepTimes = ctx.stepTimes();
        return stepTimes.length < 2 ? null : Stats.cv(stepTimes);
      case 'gait_knee_excursion_mean':
      case 'ankle_excursion_mean':
        final s = key.startsWith('ankle')
            ? ctx.angleSeries['ankle_dorsiflexion_angle_right']
            : kneeSeries;
        if (s == null || s.length < 2) return null;
        // Approximated as per-segment peak-to-peak across detected steps, so a
        // single large swing does not dominate the average.
        final segments = ctx.segmentBySteps(s);
        if (segments.isEmpty) return Stats.range(s);
        final ranges = segments
            .where((seg) => seg.length >= 2)
            .map(Stats.range)
            .toList(growable: false);
        return ranges.isEmpty ? null : Stats.mean(ranges);
      case 'gait_asymmetry_index':
        return ctx.gaitAsymmetryIndex();

      // ── static posture ────────────────────────────────────────────────
      case 'posture_knee_angle_static':
        final s = ctx.angleSeries['knee_flexion_angle_right'] ?? kneeSeries;
        return s == null || s.isEmpty ? null : Stats.mean(s);
      case 'posture_trunk_lean':
        return ctx.trunkLeanMean();
      case 'posture_pelvis_tilt':
        return ctx.pelvisTiltMean();
      case 'posture_knee_alignment_asymmetry':
        return ctx.kneeAlignmentAsymmetry();
      case 'hip_pelvis_drop':
      case 'hip_pelvis_compensation':
        return ctx.pelvisTiltMean();
      case 'balance_sway_index':
        return ctx.swayIndex();
      case 'shoulder_symmetry_index':
        return ctx.shoulderSymmetryIndex();
      case 'shoulder_elevation_compensation':
        return ctx.trunkLeanMean();
      case 'scapular_hike_proxy':
        return ctx.shoulderHeightAsymmetry();

      // ── quality ───────────────────────────────────────────────────────
      case 'knee_rom_confidence':
      case 'hip_rom_confidence':
      case 'gait_confidence':
        return _confidence(ctx.usableFrames);

      // ── explicitly research-grade; derived but never fed to the model ──
      case 'posture_varus_thrust':
      case 'squat_valgus_proxy':
        return ctx.frontalAlignmentProxy();
      case 'imu_gyro_hf_variance':
      case 'imu_relative_phase_lag':
        return null; // IMU-derived; not available from camera frames

      default:
        // Reaching here means the protocol declares a feature the extractor does
        // not implement. Returning null makes that visible as "unavailable"
        // instead of quietly inventing a number.
        return null;
    }
  }

  double _confidence(List<PoseFrame> frames) {
    if (frames.isEmpty) return 0;
    final mean = Stats.mean(frames.map((f) => f.meanLikelihood).toList());
    // Also reward coverage: a capture with very few frames is less trustworthy
    // than a dense one, even if each frame looked good.
    final coverage = (frames.length / 60).clamp(0.0, 1.0);
    return ((mean * 0.75) + (coverage * 0.25)).clamp(0.0, 1.0).toDouble();
  }
}

/// Shared state for the feature computations, so each case in [_compute] reads
/// as a formula rather than as plumbing.
class _ExtractionContext {
  _ExtractionContext({
    required this.topology,
    required this.protocol,
    required this.usableFrames,
    required this.allFrames,
    required this.angleSeries,
    required this.timeSeries,
    required this.indexByKey,
    required this.notes,
  });

  final LandmarkTopology topology;
  final JointProtocol protocol;
  final List<PoseFrame> usableFrames;
  final List<PoseFrame> allFrames;
  final Map<String, List<double>> angleSeries;
  final List<double> timeSeries;
  final Map<String, int> indexByKey;
  final List<String> notes;

  double get meanFrameInterval {
    if (timeSeries.length < 2) return 1 / 30;
    final span = timeSeries.last - timeSeries.first;
    return span <= 0 ? 1 / 30 : span / (timeSeries.length - 1);
  }

  /// Peak rate of change of an angle series, in degrees per second.
  double degreePerSecond(List<double> series) {
    if (series.length < 2) return 0;
    var peak = 0.0;
    for (var i = 1; i < series.length; i++) {
      final rate = (series[i] - series[i - 1]).abs() / meanFrameInterval;
      if (rate > peak) peak = rate;
    }
    return peak;
  }

  /// Sit-to-stand transition durations, found as contiguous windows of
  /// above-threshold vertical hip movement.
  ///
  /// A heuristic, not a validated segmentation algorithm: it is documented as
  /// such because PRD §26.5 forbids presenting a heuristic as a validated
  /// measurement pipeline. The threshold is relative to the capture's own
  /// movement scale so it adapts to camera distance.
  List<double> sitToStandDurations() {
    final hipY = <double>[];
    final times = <double>[];
    for (final frame in usableFrames) {
      final l = frame.landmark(indexByKey, 'left_hip');
      final r = frame.landmark(indexByKey, 'right_hip');
      if (l == null || r == null) continue;
      if (l.likelihood < FeatureExtractor.minLandmarkLikelihood ||
          r.likelihood < FeatureExtractor.minLandmarkLikelihood) {
        continue;
      }
      hipY.add((l.y + r.y) / 2);
      times.add(frame.seconds);
    }
    if (hipY.length < 4) return const [];

    final velocity = <double>[];
    for (var i = 1; i < hipY.length; i++) {
      final dt = times[i] - times[i - 1];
      velocity.add(dt <= 0 ? 0 : (hipY[i] - hipY[i - 1]) / dt);
    }

    final peak = Stats.max(velocity.map((v) => v.abs()).toList());
    if (peak <= 0) return const [];
    final threshold = peak * 0.25;

    final durations = <double>[];
    var runStart = -1;
    for (var i = 0; i < velocity.length; i++) {
      final active = velocity[i].abs() >= threshold;
      if (active && runStart < 0) {
        runStart = i;
      } else if (!active && runStart >= 0) {
        final duration = times[i] - times[runStart];
        if (duration > 0.15) durations.add(duration);
        runStart = -1;
      }
    }
    if (runStart >= 0) {
      final duration = times.last - times[runStart];
      if (duration > 0.15) durations.add(duration);
    }
    return durations;
  }

  /// Step events from the vertical alternation of the two ankles.
  ///
  /// Returns intervals between successive steps, in seconds. Sign changes of
  /// (left_ankle.y - right_ankle.y) correspond to mid-swing alternation, which
  /// is a standard cheap proxy when no force plate is available.
  List<double> stepTimes() {
    final crossings = <double>[];
    double? previous;
    for (final frame in usableFrames) {
      final l = frame.landmark(indexByKey, 'left_ankle');
      final r = frame.landmark(indexByKey, 'right_ankle');
      if (l == null || r == null) continue;
      if (l.likelihood < FeatureExtractor.minLandmarkLikelihood ||
          r.likelihood < FeatureExtractor.minLandmarkLikelihood) {
        continue;
      }
      final diff = l.y - r.y;
      if (previous != null && previous.sign != diff.sign) {
        crossings.add(frame.seconds);
      }
      previous = diff;
    }
    if (crossings.length < 2) return const [];

    final intervals = <double>[];
    for (var i = 1; i < crossings.length; i++) {
      final dt = crossings[i] - crossings[i - 1];
      // Reject implausible intervals: below 0.25 s or above 2 s is a landmark
      // dropout, not a step.
      if (dt >= 0.25 && dt <= 2.0) intervals.add(dt);
    }
    return intervals;
  }

  /// Splits a series into per-step segments.
  ///
  /// Segments are equal-length chunks sized from the number of detected steps.
  /// Cutting exactly on step events would make the average hypersensitive to a
  /// single mis-detected event, so the segmentation is deliberately coarse —
  /// this feeds a mean excursion figure, not a per-stride clinical measurement.
  List<List<double>> segmentBySteps(List<double> series) {
    if (series.length < 4) return const [];

    final stepTimes = this.stepTimes();
    final desired = stepTimes.isEmpty ? 2 : stepTimes.length + 1;
    // Never more segments than there are samples to fill them.
    final strideCount = desired.clamp(2, series.length ~/ 2);
    if (strideCount < 2) return const [];

    final chunkSize = series.length ~/ strideCount;
    if (chunkSize < 2) return const [];

    final segments = <List<double>>[];
    for (var start = 0; start + chunkSize <= series.length; start += chunkSize) {
      segments.add(series.sublist(start, start + chunkSize));
    }
    return segments;
  }

  double? kneeSymmetryIndex() {
    final left = angleSeries['knee_flexion_angle_left'];
    final right = angleSeries['knee_flexion_angle_right'];
    if (left == null || right == null || left.isEmpty || right.isEmpty) return null;
    return Stats.asymmetryIndex(Stats.range(left), Stats.range(right));
  }

  double? gaitAsymmetryIndex() {
    final lStep = _stepTimeFor('left_ankle', 'right_ankle');
    final rStep = _stepTimeFor('right_ankle', 'left_ankle');
    if (lStep == null || rStep == null) return null;
    return Stats.asymmetryIndex(lStep, rStep);
  }

  double? _stepTimeFor(String leading, String trailing) {
    final crossings = <double>[];
    double? previous;
    for (final frame in usableFrames) {
      final a = frame.landmark(indexByKey, leading);
      final b = frame.landmark(indexByKey, trailing);
      if (a == null || b == null) continue;
      final diff = a.y - b.y;
      if (previous != null && previous.sign != diff.sign) {
        crossings.add(frame.seconds);
      }
      previous = diff;
    }
    if (crossings.length < 2) return null;
    final intervals = <double>[];
    for (var i = 1; i < crossings.length; i++) {
      final dt = crossings[i] - crossings[i - 1];
      if (dt >= 0.25 && dt <= 2.0) intervals.add(dt);
    }
    return intervals.isEmpty ? null : Stats.mean(intervals);
  }

  double? trunkLeanMean() {
    final values = <double>[];
    for (final frame in usableFrames) {
      final hip = frame.landmark(indexByKey, 'left_hip') ??
          frame.landmark(indexByKey, 'right_hip');
      final shoulder = frame.landmark(indexByKey, 'left_shoulder') ??
          frame.landmark(indexByKey, 'right_shoulder');
      if (hip == null || shoulder == null) continue;
      values.add(FeatureExtractor.leanFromVerticalDegrees(
        hip.x, hip.y, shoulder.x, shoulder.y,
      ));
    }
    return values.isEmpty ? null : Stats.mean(values);
  }

  double? trunkThighRange() {
    final s = angleSeries['trunk_thigh_angle_right'];
    if (s == null || s.length < 2) return null;
    return Stats.range(s);
  }

  double? pelvisTiltMean() {
    final values = <double>[];
    for (final frame in usableFrames) {
      final l = frame.landmark(indexByKey, 'left_hip');
      final r = frame.landmark(indexByKey, 'right_hip');
      if (l == null || r == null) continue;
      final angle = math.atan2((r.y - l.y), (r.x - l.x)) * 180.0 / math.pi;
      values.add(angle.abs());
    }
    return values.isEmpty ? null : Stats.mean(values);
  }

  double? kneeAlignmentAsymmetry() {
    final l = angleSeries['knee_flexion_angle_left'];
    final r = angleSeries['knee_flexion_angle_right'];
    if (l == null || r == null || l.isEmpty || r.isEmpty) return null;
    return Stats.asymmetryIndex(Stats.mean(l), Stats.mean(r));
  }

  double? shoulderSymmetryIndex() {
    final values = <double>[];
    for (final frame in usableFrames) {
      final ls = frame.landmark(indexByKey, 'left_shoulder');
      final rs = frame.landmark(indexByKey, 'right_shoulder');
      if (ls == null || rs == null) continue;
      values.add((ls.y - rs.y).abs());
    }
    return values.isEmpty ? null : Stats.mean(values);
  }

  double? shoulderHeightAsymmetry() => shoulderSymmetryIndex();

  /// Postural sway from pelvis horizontal displacement over the capture.
  double? swayIndex() {
    final xs = <double>[];
    for (final frame in usableFrames) {
      final l = frame.landmark(indexByKey, 'left_hip');
      final r = frame.landmark(indexByKey, 'right_hip');
      if (l == null || r == null) continue;
      xs.add((l.x + r.x) / 2);
    }
    if (xs.length < 3) return null;
    return Stats.stdev(xs);
  }

  /// Frontal-plane alignment proxy from the hip-knee-ankle line.
  ///
  /// Research-grade only (PRD §13.4): monocular 2D varus/valgus estimation is
  /// highly sensitive to camera placement, clothing and occlusion, so this is
  /// computed for exploration and explicitly excluded from the primary model.
  double? frontalAlignmentProxy() {
    final values = <double>[];
    for (final frame in usableFrames) {
      final hip = frame.landmark(indexByKey, 'left_hip');
      final knee = frame.landmark(indexByKey, 'left_knee');
      final ankle = frame.landmark(indexByKey, 'left_ankle');
      if (hip == null || knee == null || ankle == null) continue;
      final hipToKnee = hip.x - knee.x;
      final kneeToAnkle = knee.x - ankle.x;
      values.add((hipToKnee - kneeToAnkle).abs() * 100);
    }
    return values.isEmpty ? null : Stats.mean(values);
  }
}
