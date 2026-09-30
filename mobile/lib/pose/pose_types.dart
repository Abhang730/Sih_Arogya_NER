// Pose perception types and the engine boundary (PRD §10.1).
//
// PRD §10.1 names MediaPipe BlazePose as the primary pose engine, with
// YOLOv8n-pose as a benchmark alternative. There is no official MediaPipe
// Flutter plugin, so the shipped engine is Google ML Kit Pose Detection, which
// is the same BlazePose-family model and the same 33-landmark topology
// (verified against Google's Pose Landmarker documentation).
//
// Everything downstream talks to [PoseEngine] rather than to ML Kit, so the
// engine can be swapped — to a native MediaPipe Tasks channel, or to YOLOv8n —
// without touching the feature extractor or any screen.

import 'dart:async';

import '../domain/protocol/models.dart';

/// One detected body landmark in normalized image coordinates.
class PoseLandmark {
  const PoseLandmark({
    required this.key,
    required this.x,
    required this.y,
    this.z = 0,
    this.likelihood = 1,
  });

  final String key;

  /// Normalized to [0,1] relative to the image width/height.
  final double x;
  final double y;

  /// Depth relative to the hip midpoint. On-device ML Kit returns no world
  /// coordinates, so this is the coarse relative z only.
  final double z;

  /// Detection confidence in [0,1] ("in-frame likelihood"). Drives the quality
  /// gate (PRD §9.4) and every per-feature confidence score (PRD §15.4).
  final double likelihood;

  PoseLandmark copyWith({double? x, double? y, double? z, double? likelihood}) =>
      PoseLandmark(
        key: key,
        x: x ?? this.x,
        y: y ?? this.y,
        z: z ?? this.z,
        likelihood: likelihood ?? this.likelihood,
      );

  @override
  String toString() =>
      'PoseLandmark($key, x: ${x.toStringAsFixed(3)}, y: ${y.toStringAsFixed(3)}, '
      'likelihood: ${likelihood.toStringAsFixed(2)})';
}

/// A single captured pose frame: exactly one landmark per topology entry, in
/// topology order. Frames are the unit the feature extractor consumes.
class PoseFrame {
  const PoseFrame({required this.timestampUs, required this.landmarks});

  /// Monotonic capture timestamp in microseconds, supplied by the capture
  /// source rather than by wall-clock time so gait timing survives a clock
  /// adjustment mid-capture.
  final int timestampUs;

  /// Ordered to match [LandmarkTopology.landmarks], so index lookup is O(1).
  final List<PoseLandmark> landmarks;

  double get seconds => timestampUs / 1000000.0;

  /// Mean detection confidence across the frame. A low value means the whole
  /// frame is unreliable, not just one joint.
  double get meanLikelihood {
    if (landmarks.isEmpty) return 0;
    var sum = 0.0;
    for (final l in landmarks) {
      sum += l.likelihood;
    }
    return sum / landmarks.length;
  }

  /// Reads a landmark by topology key, returning null when absent.
  PoseLandmark? landmark(Map<String, int> indexByKey, String key) {
    final index = indexByKey[key];
    if (index == null || index < 0 || index >= landmarks.length) return null;
    return landmarks[index];
  }

  /// Clears the face and hand landmarks that the 33-point topology includes but
  /// this product never uses. They are pure noise for musculoskeletal screening
  /// and they drag down [meanLikelihood] on a normal full-body frame, so they
  /// are zeroed rather than deleted to keep indices stable.
  PoseFrame zeroUnusedLandmarks() {
    const used = {
      'nose', 'left_ear', 'right_ear',
      'left_shoulder', 'right_shoulder',
      'left_elbow', 'right_elbow',
      'left_wrist', 'right_wrist',
      'left_hip', 'right_hip',
      'left_knee', 'right_knee',
      'left_ankle', 'right_ankle',
      'left_heel', 'right_heel',
      'left_foot_index', 'right_foot_index',
    };
    return PoseFrame(
      timestampUs: timestampUs,
      landmarks: landmarks
          .map((l) => used.contains(l.key)
              ? l
              : PoseLandmark(key: l.key, x: l.x, y: l.y, z: l.z, likelihood: 1))
          .toList(growable: false),
    );
  }
}

/// Thrown when a pose engine cannot be created or initialised.
class PoseEngineException implements Exception {
  PoseEngineException(this.message);

  final String message;

  @override
  String toString() => 'PoseEngineException: $message';
}

/// The boundary every pose implementation sits behind.
abstract class PoseEngine {
  /// Human-readable engine name, recorded with every assessment for model and
  /// protocol traceability (PRD §27.2).
  String get engineId;

  /// Whether this engine produces real measurements.
  ///
  /// False means the output is synthetic. The UI MUST label results derived
  /// from a synthetic engine, because presenting generated landmarks as a
  /// patient measurement would be a fabricated clinical claim (PRD §1.2).
  bool get isSynthetic;

  Future<void> initialize();
  Stream<PoseFrame> get frames;
  Future<void> dispose();
}

/// A pose engine that wraps a single-image detector.
///
/// Camera capture, frame throttling and lifecycle live in the capture screen,
/// not here, so this stays testable without a camera.
abstract class FramePoseEngine extends PoseEngine {
  /// Runs detection on one frame's raw bytes.
  Future<PoseFrame> detectFrame({
    required List<int> bytes,
    required int width,
    required int height,
    required int rotationDegrees,
    required int timestampUs,
  });
}
