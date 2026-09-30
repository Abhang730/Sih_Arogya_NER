// Synthetic pose engine.
//
// Two jobs, and only two:
//
//   1. Tests. Because the generator is geometrically self-consistent, the knee
//      angle it draws is a KNOWN value. That lets the feature extractor be
//      tested against ground truth instead of against its own output — the
//      difference between a test that catches a regression and a test that just
//      freezes a bug.
//   2. Demos on hardware where the real engine cannot run (an emulator without
//      camera passthrough, a desktop build). Every result it produces carries
//      isSynthetic = true, and the UI MUST label it, because presenting
//      generated landmarks as a patient measurement would be a fabricated
//      clinical claim (PRD §1.2).

import 'dart:async';
import 'dart:math' as math;

import '../domain/protocol/models.dart';
import 'pose_types.dart';

/// What the synthetic patient is doing.
enum SyntheticMotion {
  /// Quiet standing with a near-straight knee.
  standing,

  /// Standing with a fixed, caller-chosen knee flexion.
  fixedFlexion,

  /// Five sit-to-stand repetitions.
  sitToStand,

  /// Continuous walking with a sinusoidal knee flexion cycle.
  walking,
}

/// Builds geometrically consistent landmark frames from a small 2D kinematic
/// model of a standing human.
///
/// The model is deliberately simple: a thigh and a shank of equal length [limb]
/// meeting at the knee. Given a desired knee flexion angle f and a leg
/// direction, the ankle and knee positions follow from the law of cosines:
///
///     hip-to-ankle distance d = 2 * L * cos(f / 2)
///     knee offset from midpoint h = L * sin(f / 2)
///
/// so a straight leg (f = 0) puts the knee on the line, and a deeply flexed leg
/// folds it.
class SyntheticPoseFactory {
  SyntheticPoseFactory({required this.topology, this.limb = 0.1, this.seed = 7})
      : _random = math.Random(seed);

  final LandmarkTopology topology;

  /// Thigh and shank length, as a fraction of frame height. 0.1 keeps a full
  /// standing figure inside the frame with room for the head.
  ///
  /// Kept as the default because the feature-extractor tests reason about joint
  /// ANGLE, which is scale-invariant, and a smaller figure keeps their synthetic
  /// coordinates readable.
  final double limb;
  final int seed;

  /// Limb length that makes the synthetic figure span the frame the way a real
  /// patient filmed from a few metres does.
  ///
  /// The capture quality gate requires the head-to-ankle span to cover at least
  /// 75% of the frame height, which is a real framing rule a worker has to
  /// satisfy. A demonstration capture at [limb] = 0.1 fails it, and the honest
  /// fix is to draw a properly framed figure rather than to weaken the check for
  /// the demo build.
  ///
  /// Sized so that the framing check passes for every motion the demo uses,
  /// including walking, where the legs swing forward and the head-to-ankle span
  /// shortens. A figure that only just clears the threshold makes the capture
  /// button flicker between enabled and disabled, which is a worse demonstration
  /// than a slightly larger figure.
  static const double fullBodyLimb = 0.20;
  final math.Random _random;

  /// Centre of the standing figure.
  static const double hipYStanding = 0.52;
  static const double hipYSitting = 0.66;

  /// Builds one frame for the given motion state.
  PoseFrame frame({
    required SyntheticMotion motion,
    required double t,
    double fixedFlexionDeg = 8,
    double noise = 0.0015,
    int fps = 30,
  }) {
    final points = <String, _P>{
      'nose': const _P(0.5, 0.135),
      'left_ear': const _P(0.472, 0.15),
      'right_ear': const _P(0.528, 0.15),
      'left_shoulder': const _P(0.44, 0.27),
      'right_shoulder': const _P(0.56, 0.27),
      'left_elbow': const _P(0.415, 0.41),
      'right_elbow': const _P(0.585, 0.41),
      'left_wrist': const _P(0.40, 0.54),
      'right_wrist': const _P(0.60, 0.54),
    };

    // Face and hand landmarks the product never uses, but which must exist so
    // the frame has one entry per topology slot.
    for (final landmark in topology.landmarks) {
      points.putIfAbsent(landmark.key, () => const _P(0.5, 0.5));
    }

    final leftHip = _P(0.455, 0.52);
    final rightHip = _P(0.545, 0.52);
    var hipY = hipYStanding;
    var leftFlexion = 5.0;
    var rightFlexion = 5.0;
    var leftSwing = 0.0;
    var rightSwing = 0.0;
    var leftHipDrop = 0.0;
    var rightHipDrop = 0.0;
    var trunkLeans = 0.0;

    switch (motion) {
      case SyntheticMotion.standing:
        break;

      case SyntheticMotion.fixedFlexion:
        leftFlexion = fixedFlexionDeg;
        rightFlexion = fixedFlexionDeg;

      case SyntheticMotion.sitToStand:
        // Five cycles: 1.6 s seated, 1.2 s rising, 1.0 s standing, then down.
        const cycle = 3.8;
        final phase = t % cycle;
        double progress;
        if (phase < 1.2) {
          progress = 0;
        } else if (phase < 2.4) {
          progress = (phase - 1.2) / 1.2;
        } else if (phase < 3.0) {
          progress = 1;
        } else {
          progress = 1 - (phase - 3.0) / 0.8;
        }
        final eased = progress * progress * (3 - 2 * progress); // smoothstep
        hipY = hipYSitting - (hipYSitting - hipYStanding) * eased;
        // Seated knee is ~90 degrees, standing ~8.
        leftFlexion = 90 - 82 * eased;
        rightFlexion = 90 - 82 * eased;
        // Trunk leans forward to rise, peaking mid-transition.
        trunkLeans = 22 * math.sin(eased * math.pi);

      case SyntheticMotion.walking:
        // ~1.1 s gait cycle: flexion oscillates between 5 and 55 degrees,
        // offset by half a cycle between legs.
        final cycle = 2 * math.pi * t / 1.1;
        leftFlexion = 30 - 25 * math.cos(cycle);
        rightFlexion = 30 - 25 * math.cos(cycle + math.pi);
        leftSwing = 0.22 * math.sin(cycle);
        rightSwing = 0.22 * math.sin(cycle + math.pi);
        // Pelvis drops slightly on the swing side.
        leftHipDrop = 0.004 * math.sin(cycle);
        rightHipDrop = 0.004 * math.sin(cycle + math.pi);
        // Trunk bobs a little.
        trunkLeans = 1.5 * math.sin(2 * cycle);
        hipY = hipYStanding + 0.006 * math.sin(2 * cycle);
    }

    final left = _leg(
      hip: _P(leftHip.x, hipY + leftHipDrop),
      flexionDeg: leftFlexion,
      swing: leftSwing,
    );
    final right = _leg(
      hip: _P(rightHip.x, hipY + rightHipDrop),
      flexionDeg: rightFlexion,
      swing: rightSwing,
    );

    points['left_hip'] = _P(leftHip.x, hipY + leftHipDrop);
    points['right_hip'] = _P(rightHip.x, hipY + rightHipDrop);
    points['left_knee'] = left.knee;
    points['right_knee'] = right.knee;
    points['left_ankle'] = left.ankle;
    points['right_ankle'] = right.ankle;
    points['left_heel'] = _P(left.ankle.x - 0.005, left.ankle.y + 0.02);
    points['right_heel'] = _P(right.ankle.x - 0.005, right.ankle.y + 0.02);
    points['left_foot_index'] = _P(left.ankle.x + 0.03, left.ankle.y + 0.025);
    points['right_foot_index'] = _P(right.ankle.x + 0.03, right.ankle.y + 0.025);

    // Forward trunk lean rotates the upper body about the hip line.
    if (trunkLeans.abs() > 0.01) {
      final radians = trunkLeans * math.pi / 180;
      for (final key in [
        'nose', 'left_ear', 'right_ear',
        'left_shoulder', 'right_shoulder',
        'left_elbow', 'right_elbow',
        'left_wrist', 'right_wrist',
      ]) {
        final p = points[key]!;
        final dy = p.y - hipY;
        final dx = p.x - 0.5;
        points[key] = _P(
          0.5 + dx - math.sin(radians) * dy * 0.5,
          hipY + dy * math.cos(radians),
        );
      }
    }

    final landmarks = <PoseLandmark>[];
    for (final landmark in topology.landmarks) {
      final p = points[landmark.key] ?? const _P(0.5, 0.5);
      landmarks.add(PoseLandmark(
        key: landmark.key,
        x: p.x + _jitter(noise),
        y: p.y + _jitter(noise),
        // Likelihood is high and stable so the quality gate passes: this engine
        // exists to exercise the pipeline, not the gate (which has its own
        // tests with deliberately degraded frames).
        likelihood: 0.92,
      ));
    }

    return PoseFrame(
      timestampUs: (t * 1000000).round(),
      landmarks: landmarks,
    );
  }

  /// Builds a capture of [durationSeconds] for the given motion.
  List<PoseFrame> sequence({
    required SyntheticMotion motion,
    double durationSeconds = 6,
    double fixedFlexionDeg = 8,
    int fps = 30,
    double noise = 0.0015,
  }) {
    final frames = <PoseFrame>[];
    final count = (durationSeconds * fps).round();
    for (var i = 0; i < count; i++) {
      frames.add(frame(
        motion: motion,
        t: i / fps,
        fixedFlexionDeg: fixedFlexionDeg,
        noise: noise,
        fps: fps,
      ));
    }
    return frames;
  }

  double _jitter(double amplitude) =>
      amplitude == 0 ? 0 : (_random.nextDouble() * 2 - 1) * amplitude;

  /// Places the knee and ankle for a leg rooted at [hip] and flexed by
  /// [flexionDeg].
  ///
  /// The knee is positioned exactly on the perpendicular bisector of the
  /// hip-to-ankle line at distance h = L*sin(f/2) from its midpoint. That makes
  /// |hip-knee| = |knee-ankle| = L and the included angle at the knee exactly
  /// (180 - f), so the feature extractor must recover f. Approximating the knee
  /// position by eye instead would make this generator useless as ground truth
  /// — the test would then only be asserting that the extractor reproduces
  /// whatever the generator happened to draw.
  ({_P knee, _P ankle}) _leg({
    required _P hip,
    required double flexionDeg,
    required double swing,
  }) {
    final radians = flexionDeg * math.pi / 180;
    final d = 2 * limb * math.cos(radians / 2);
    final h = limb * math.sin(radians / 2);

    // Leg direction: straight down, rotated by the swing angle.
    final dirX = math.sin(swing);
    final dirY = math.cos(swing);
    final ankle = _P(hip.x + dirX * d, hip.y + dirY * d);

    final dx = ankle.x - hip.x;
    final dy = ankle.y - hip.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return (knee: hip, ankle: ankle);

    // Perpendicular pointing forward (+x when the hip is directly above the
    // ankle), so a flexed knee bows consistently in front of the joint line.
    final perpX = dy / len;
    final perpY = -dx / len;

    final midX = (hip.x + ankle.x) / 2;
    final midY = (hip.y + ankle.y) / 2;
    return (
      knee: _P(midX + perpX * h, midY + perpY * h),
      ankle: ankle,
    );
  }
}

/// A [PoseEngine] that replays a synthetic capture.
///
/// Present so the screening screens have something to run against on hardware
/// without the real detector. It is never a substitute for the real engine in
/// the field, and says so through [isSynthetic].
class SyntheticPoseEngine implements PoseEngine {
  SyntheticPoseEngine({
    required this.topology,
    this.motion = SyntheticMotion.walking,
    this.durationSeconds = 6,
    this.fps = 30,
  });

  final LandmarkTopology topology;
  final SyntheticMotion motion;
  final double durationSeconds;
  final int fps;

  final _controller = StreamController<PoseFrame>.broadcast();
  Timer? _timer;
  var _index = 0;
  List<PoseFrame> _frames = const [];

  @override
  String get engineId => 'synthetic_v1';

  @override
  bool get isSynthetic => true;

  @override
  Future<void> initialize() async {
    _frames = SyntheticPoseFactory(
      topology: topology,
      limb: SyntheticPoseFactory.fullBodyLimb,
    ).sequence(
      motion: motion,
      durationSeconds: durationSeconds,
      fps: fps,
    );
    _index = 0;
  }

  @override
  Stream<PoseFrame> get frames => _controller.stream;

  /// Starts replaying the synthetic capture in real time.
  void start() {
    _timer?.cancel();
    final interval = Duration(microseconds: (1000000 / fps).round());
    _timer = Timer.periodic(interval, (_) {
      if (_index >= _frames.length) {
        _index = 0; // loop, so a demo screen never goes blank
      }
      if (!_controller.isClosed) {
        _controller.add(_frames[_index]);
      }
      _index++;
    });
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _controller.close();
  }
}

class _P {
  const _P(this.x, this.y);

  final double x;
  final double y;
}
