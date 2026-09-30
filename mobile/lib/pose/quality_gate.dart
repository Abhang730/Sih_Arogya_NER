// Capture quality gate (PRD §9.4, §15.4).
//
// PRD §9.4 is explicit that if pose confidence is too low the worker must be
// asked to reposition "rather than silently accepting poor data". PRD §19.2
// adds: "Never hide a failed quality check." So this gate returns a *reason* for
// every check, written as an instruction, and the UI is expected to display
// failures rather than degrade quietly.
//
// The gate is a safety control as much as a data-quality one: refusing a bad
// capture is the cheapest way to avoid a confident-looking number derived from
// unusable input.

import 'dart:math' as math;

import '../domain/protocol/models.dart';
import 'pose_types.dart';

/// What a quality check is about.
enum QualityCheckId {
  fullBodyInFrame,
  lighting,
  poseConfidence,
  stability,
  landmarkVisibility;

  String get wire => switch (this) {
        QualityCheckId.fullBodyInFrame => 'full_body_in_frame',
        QualityCheckId.lighting => 'lighting',
        QualityCheckId.poseConfidence => 'pose_confidence',
        QualityCheckId.stability => 'stability',
        QualityCheckId.landmarkVisibility => 'landmark_visibility',
      };
}

/// Outcome of one quality check.
///
/// Three states rather than two, because "we could not measure this" is a
/// different statement from both "it passed" and "it failed". Collapsing it into
/// either one is a real defect: as a pass it fabricates a clean capture, and as a
/// failure it blocks a worker whose capture is fine — which is what a gate that
/// treats unmeasurable lighting as a failure does.
///
/// A [notMeasured] check never blocks and is always still shown, so the rule in
/// PRD §19.2 ("never hide a failed quality check") and the rule in §26.5 ("a
/// missing measurement is not a value") are both satisfied at once.
enum QualityCheckResult {
  passed,
  failed,
  notMeasured;
}

class QualityCheck {
  const QualityCheck({
    required this.id,
    required this.result,
    required this.detail,
    this.measuredValue,
    this.threshold,
  });

  final QualityCheckId id;
  final QualityCheckResult result;

  bool get passed => result == QualityCheckResult.passed;
  bool get failed => result == QualityCheckResult.failed;
  bool get notMeasured => result == QualityCheckResult.notMeasured;

  /// Worker-facing explanation. Written as an instruction ("Step back so your
  /// whole body is visible"), never as a bare error code.
  final String detail;
  final double? measuredValue;
  final double? threshold;

  Map<String, dynamic> toJson() => {
        'id': id.wire,
        'result': result.name,
        'passed': passed,
        'detail': detail,
        if (measuredValue != null) 'measured': measuredValue,
        if (threshold != null) 'threshold': threshold,
      };
}

class QualityReport {
  const QualityReport({required this.checks, required this.score});

  final List<QualityCheck> checks;

  /// Aggregate 0..1 modality confidence consumed by the fusion layer
  /// (PRD §15.4, §17.5).
  final double score;

  /// Whether capture may proceed. A check that could not be measured does not
  /// block: it is reported, not treated as a failure.
  bool get passed => checks.every((c) => !c.failed);

  List<QualityCheck> get failures =>
      checks.where((c) => c.failed).toList(growable: false);

  /// Checks that could not be evaluated at all, e.g. lighting when there is no
  /// camera image because the pose engine is synthetic.
  List<QualityCheck> get notMeasured =>
      checks.where((c) => c.notMeasured).toList(growable: false);

  /// True when the capture is usable but something about it was not verified.
  bool get hasUnverifiedChecks => notMeasured.isNotEmpty;

  /// Worker-facing summary of everything that needs fixing, plus anything that
  /// could not be checked.
  String get workerMessage {
    if (failures.isNotEmpty) return failures.map((f) => f.detail).join(' ');
    if (notMeasured.isNotEmpty) {
      return 'Ready to start. Not checked here: '
          '${notMeasured.map((c) => c.detail).join(' ')}';
    }
    return 'Ready to start';
  }

  QualityCheck? operator [](QualityCheckId id) {
    for (final c in checks) {
      if (c.id == id) return c;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'passed': passed,
        'score': score,
        'checks': checks.map((c) => c.toJson()).toList(growable: false),
      };
}

/// Thresholds for the gate.
///
/// Defaults come from the protocol's landmark quality block. They are
/// deliberately configurable because the correct values depend on the device
/// and the room, and can only be fixed by the device benchmark the PRD calls
/// for (M9, §32.3).
class QualityGateConfig {
  const QualityGateConfig({
    this.minLikelihood = 0.5,
    this.minLighting = 0.25,
    this.maxCentreOffset = 0.18,
    this.minVerticalSpan = 0.75,
    this.maxStabilityJitter = 0.035,
  });

  final double minLikelihood;
  final double minLighting;

  /// How far the body's horizontal centre may sit from the frame centre, as a
  /// fraction of frame width.
  final double maxCentreOffset;

  /// Head-to-ankle vertical span required to count as "full body in frame".
  final double minVerticalSpan;

  /// Maximum centroid movement between frames for a *static* capture.
  final double maxStabilityJitter;

  factory QualityGateConfig.fromTopology(LandmarkTopology topology) =>
      QualityGateConfig(
        minLikelihood: topology.qualityGate.defaultMinLikelihood,
        minLighting: topology.qualityGate.defaultMinLighting,
      );

  QualityGateConfig copyWith({
    double? minLikelihood,
    double? minLighting,
    double? maxCentreOffset,
    double? minVerticalSpan,
    double? maxStabilityJitter,
  }) =>
      QualityGateConfig(
        minLikelihood: minLikelihood ?? this.minLikelihood,
        minLighting: minLighting ?? this.minLighting,
        maxCentreOffset: maxCentreOffset ?? this.maxCentreOffset,
        minVerticalSpan: minVerticalSpan ?? this.minVerticalSpan,
        maxStabilityJitter: maxStabilityJitter ?? this.maxStabilityJitter,
      );
}

class QualityGate {
  const QualityGate({
    required this.topology,
    this.config = const QualityGateConfig(),
  });

  final LandmarkTopology topology;
  final QualityGateConfig config;

  /// Evaluates one frame.
  ///
  /// [meanLuma] is mean frame brightness in 0..1 from the capture layer. When
  /// null the lighting check reports as *not measured* rather than passing,
  /// because a fabricated pass is exactly the "silently accepting poor data"
  /// behaviour PRD §9.4 forbids.
  QualityReport evaluate({
    required PoseFrame frame,
    double? meanLuma,
    List<PoseFrame> recentFrames = const [],
    bool staticCapture = false,
    /// Whether the capture has a real camera image behind it. False for the
    /// synthetic pose engine, where a lighting check is impossible rather than
    /// pending.
    bool hasCameraImage = true,
  }) {
    final checks = <QualityCheck>[];
    final indexByKey = topology.indexByKey;

    // ── landmark visibility, per the named regions in PRD §9.4 ───────────
    final visibilityFailures = <String>[];
    var regionLikelihoodSum = 0.0;
    var regionLandmarkCount = 0;

    for (final entry in topology.qualityGate.referenceLandmarks.entries) {
      var regionSum = 0.0;
      var regionCount = 0;
      for (final key in entry.value) {
        final landmark = frame.landmark(indexByKey, key);
        regionCount++;
        if (landmark != null) regionSum += landmark.likelihood;
      }
      regionLikelihoodSum += regionSum;
      regionLandmarkCount += regionCount;
      final regionMean = regionCount == 0 ? 0.0 : regionSum / regionCount;
      if (regionMean < config.minLikelihood) {
        visibilityFailures.add(entry.key);
      }
    }

    final meanLikelihood =
        regionLandmarkCount == 0 ? 0.0 : regionLikelihoodSum / regionLandmarkCount;

    checks.add(QualityCheck(
      id: QualityCheckId.landmarkVisibility,
      result: visibilityFailures.isEmpty
          ? QualityCheckResult.passed
          : QualityCheckResult.failed,
      detail: visibilityFailures.isEmpty
          ? 'Head, shoulders, hips, knees and ankles all detected'
          : 'Not detected clearly: ${visibilityFailures.join(', ')}. '
              'Ask the patient to face the camera and step back.',
      measuredValue: meanLikelihood,
      threshold: config.minLikelihood,
    ));

    checks.add(QualityCheck(
      id: QualityCheckId.poseConfidence,
      result: meanLikelihood >= config.minLikelihood
          ? QualityCheckResult.passed
          : QualityCheckResult.failed,
      detail: meanLikelihood >= config.minLikelihood
          ? 'Pose confidence is sufficient'
          : 'Pose confidence is too low. Improve the lighting and remove '
              'anything blocking the view of the body.',
      measuredValue: meanLikelihood,
      threshold: config.minLikelihood,
    ));

    // ── full body in frame ────────────────────────────────────────────────
    // Two independent things can go wrong (the body is too small to fit, or it
    // is off-centre), so they are merged into ONE check carrying a single
    // instruction. Two checks sharing an id would make the report ambiguous
    // both to read and to consume downstream.
    final head = frame.landmark(indexByKey, 'nose');
    final ankles = [
      frame.landmark(indexByKey, 'left_ankle'),
      frame.landmark(indexByKey, 'right_ankle'),
    ].whereType<PoseLandmark>().toList(growable: false);
    final hips = [
      frame.landmark(indexByKey, 'left_hip'),
      frame.landmark(indexByKey, 'right_hip'),
    ].whereType<PoseLandmark>().toList(growable: false);

    double? verticalSpan;
    if (head != null &&
        ankles.isNotEmpty &&
        head.likelihood >= config.minLikelihood) {
      final lowestAnkleY = ankles.map((a) => a.y).reduce(math.max);
      verticalSpan = lowestAnkleY - head.y;
    }

    // Horizontal centring also keeps the body clear of edge lens distortion.
    final centreOffsetX = hips.isEmpty
        ? null
        : (hips.map((h) => h.x).reduce((a, b) => a + b) / hips.length - 0.5).abs();

    final spanOk = verticalSpan != null && verticalSpan >= config.minVerticalSpan;
    final centredOk =
        centreOffsetX != null && centreOffsetX <= config.maxCentreOffset;
    final fullBodyPassed = spanOk && centredOk;

    final String fullBodyDetail;
    if (fullBodyPassed) {
      fullBodyDetail = 'Full body is in frame and centred';
    } else if (!spanOk && !centredOk) {
      fullBodyDetail = 'Full body is not in frame. Move the phone back so the '
          'head and both feet are visible, and centre the patient.';
    } else if (!spanOk) {
      fullBodyDetail = 'Full body is not in frame. Move the phone back so the '
          'head and both feet are visible.';
    } else {
      fullBodyDetail = 'Move the patient to the centre of the frame.';
    }

    checks.add(QualityCheck(
      id: QualityCheckId.fullBodyInFrame,
      result: fullBodyPassed
          ? QualityCheckResult.passed
          : QualityCheckResult.failed,
      detail: fullBodyDetail,
      measuredValue: verticalSpan,
      threshold: config.minVerticalSpan,
    ));

    // ── lighting ─────────────────────────────────────────────────────────
    //
    // [meanLuma] is null in two different situations, and the gate must not
    // confuse them. One is "the camera has not produced a frame yet" — a
    // transient state the worker resolves by holding the phone steady. The other
    // is "this capture has no camera image at all", which is the synthetic pose
    // engine used by the web and desktop builds. The caller tells the two apart
    // with [hasCameraImage], because a gate that guessed would either block a
    // working capture forever or report a fabricated lighting pass.
    if (meanLuma == null) {
      checks.add(QualityCheck(
        id: QualityCheckId.lighting,
        result: hasCameraImage
            ? QualityCheckResult.notMeasured
            : QualityCheckResult.notMeasured,
        detail: hasCameraImage
            ? 'Lighting has not been measured yet. Hold the camera steady for a '
                'moment so the check can run.'
            : 'Lighting is not checked on this build: the landmarks are '
                'generated, so there is no camera image to measure.',
      ));
    } else {
      final lightingPassed = meanLuma >= config.minLighting;
      checks.add(QualityCheck(
        id: QualityCheckId.lighting,
        result: lightingPassed
            ? QualityCheckResult.passed
            : QualityCheckResult.failed,
        detail: lightingPassed
            ? 'Lighting is adequate'
            : 'Too dark to measure reliably. Move to a brighter area or face '
                'a window.',
        measuredValue: meanLuma,
        threshold: config.minLighting,
      ));
    }

    // ── stability, for static captures only ──────────────────────────────
    if (staticCapture) {
      if (recentFrames.length < 3) {
        // Not enough frames *yet*. This is reported as not measured rather than
        // as a failure so the check cannot deadlock: the caller can only supply
        // recent frames once frames start arriving, and frames only start
        // arriving once the worker is allowed to capture.
        checks.add(const QualityCheck(
          id: QualityCheckId.stability,
          result: QualityCheckResult.notMeasured,
          detail: 'Hold still for a moment longer to complete the stability check.',
        ));
      } else {
        final centroids = <double>[];
        for (final f in recentFrames) {
          final fHips = [
            f.landmark(indexByKey, 'left_hip'),
            f.landmark(indexByKey, 'right_hip'),
          ].whereType<PoseLandmark>().toList(growable: false);
          if (fHips.length == 2) {
            centroids.add(fHips.map((h) => h.x).reduce((a, b) => a + b) / 2);
          }
        }
        final jitter =
            centroids.length < 2 ? 0.0 : (centroids.last - centroids.first).abs();
        final stable = jitter <= config.maxStabilityJitter;
        checks.add(QualityCheck(
          id: QualityCheckId.stability,
          result: stable
              ? QualityCheckResult.passed
              : QualityCheckResult.failed,
          detail: stable
              ? 'Patient is steady'
              : 'The patient is moving. Ask them to stand still for a few seconds.',
          measuredValue: jitter,
          threshold: config.maxStabilityJitter,
        ));
      }
    }

    return QualityReport(checks: checks, score: _score(checks));
  }

  /// Aggregate confidence.
  ///
  /// Averaged over the checks the caller actually ran, so a gait capture (which
  /// skips the stability check) is not penalised for skipping it. Lighting is
  /// weighted down because it is a coarse proxy for a factor that also shows up
  /// through pose confidence, and double-counting it would over-penalise a dim
  /// but otherwise perfectly usable capture.
  ///
  /// A single hard failure caps the whole aggregate. Without that, a capture
  /// that failed one check while passing three could score in the 0.6-0.7 range
  /// and read downstream as a good capture, which is the opposite of what a
  /// quality gate is for. A check that could not be measured does NOT cap it,
  /// because "unverified" is not a failure.
  double _score(List<QualityCheck> checks) {
    if (checks.isEmpty) return 0.0;
    var weighted = 0.0;
    var weightSum = 0.0;

    for (final check in checks) {
      final weight = check.id == QualityCheckId.lighting ? 0.5 : 1.0;
      final raw = check.measuredValue;
      final threshold = check.threshold;

      double value;
      if (check.notMeasured) {
        // Neither evidence of a good capture nor of a bad one. Scored neutrally
        // and deliberately NOT capped: a check that could not run must not drag
        // the capture below the threshold that a downstream consumer reads as
        // "untrustworthy".
        value = 0.5;
      } else {
        if (raw != null && threshold != null && threshold > 0) {
          // Reward exceeding the threshold, saturating at 1.0.
          value = (raw / (threshold * 2)).clamp(0.0, 1.0).toDouble();
        } else {
          value = check.passed ? 1.0 : 0.0;
        }
        if (check.failed) {
          // A hard failure must cap the aggregate: a capture that failed a check
          // is not "mostly fine", and letting it score high would let it through
          // fusion as if it were trustworthy.
          value = math.min(value, 0.4);
        }
      }
      weighted += value * weight;
      weightSum += weight;
    }

    final aggregate =
        weightSum == 0 ? 0.0 : (weighted / weightSum).clamp(0.0, 1.0).toDouble();

    if (checks.any((c) => c.failed)) {
      return math.min(aggregate, 0.4);
    }
    return aggregate;
  }
}
