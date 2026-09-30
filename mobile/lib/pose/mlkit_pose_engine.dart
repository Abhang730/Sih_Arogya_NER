// On-device pose engine (PRD §10.1).
//
// PRD §10.1 names MediaPipe BlazePose primary and YOLOv8n-pose as the
// benchmark alternative. There is no official MediaPipe Flutter plugin, so this
// engine uses Google ML Kit Pose Detection, which is built on BlazePose and
// emits the identical 33-landmark topology (both verified against Google's
// Pose Landmarker documentation).
//
// This file is the ONLY place in the app that imports ML Kit, and it does so
// behind a prefix because ML Kit exports its own `PoseLandmark` type that would
// otherwise collide with the app's domain type. Everything else depends on the
// [FramePoseEngine] interface, so swapping in a native MediaPipe Tasks channel
// or YOLOv8n later touches only this boundary (PRD §29 Maintainability).
//
// Platform note: ML Kit has no web or desktop implementation. Callers must fall
// back to SyntheticPoseEngine there, and label the results as synthetic.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart'
    as mlkit;

import '../domain/protocol/models.dart';
import 'pose_types.dart';

/// Maps the app's topology keys onto ML Kit's landmark type enum.
///
/// Written as an explicit switch rather than by index so that a change in ML
/// Kit's enum ordering becomes a compile error rather than a silently scrambled
/// skeleton.
mlkit.PoseLandmarkType? _mlKitTypeFor(String key) => switch (key) {
      'nose' => mlkit.PoseLandmarkType.nose,
      'left_eye_inner' => mlkit.PoseLandmarkType.leftEyeInner,
      'left_eye' => mlkit.PoseLandmarkType.leftEye,
      'left_eye_outer' => mlkit.PoseLandmarkType.leftEyeOuter,
      'right_eye_inner' => mlkit.PoseLandmarkType.rightEyeInner,
      'right_eye' => mlkit.PoseLandmarkType.rightEye,
      'right_eye_outer' => mlkit.PoseLandmarkType.rightEyeOuter,
      'left_ear' => mlkit.PoseLandmarkType.leftEar,
      'right_ear' => mlkit.PoseLandmarkType.rightEar,
      'mouth_left' => mlkit.PoseLandmarkType.leftMouth,
      'mouth_right' => mlkit.PoseLandmarkType.rightMouth,
      'left_shoulder' => mlkit.PoseLandmarkType.leftShoulder,
      'right_shoulder' => mlkit.PoseLandmarkType.rightShoulder,
      'left_elbow' => mlkit.PoseLandmarkType.leftElbow,
      'right_elbow' => mlkit.PoseLandmarkType.rightElbow,
      'left_wrist' => mlkit.PoseLandmarkType.leftWrist,
      'right_wrist' => mlkit.PoseLandmarkType.rightWrist,
      'left_pinky' => mlkit.PoseLandmarkType.leftPinky,
      'right_pinky' => mlkit.PoseLandmarkType.rightPinky,
      'left_index' => mlkit.PoseLandmarkType.leftIndex,
      'right_index' => mlkit.PoseLandmarkType.rightIndex,
      'left_thumb' => mlkit.PoseLandmarkType.leftThumb,
      'right_thumb' => mlkit.PoseLandmarkType.rightThumb,
      'left_hip' => mlkit.PoseLandmarkType.leftHip,
      'right_hip' => mlkit.PoseLandmarkType.rightHip,
      'left_knee' => mlkit.PoseLandmarkType.leftKnee,
      'right_knee' => mlkit.PoseLandmarkType.rightKnee,
      'left_ankle' => mlkit.PoseLandmarkType.leftAnkle,
      'right_ankle' => mlkit.PoseLandmarkType.rightAnkle,
      'left_heel' => mlkit.PoseLandmarkType.leftHeel,
      'right_heel' => mlkit.PoseLandmarkType.rightHeel,
      'left_foot_index' => mlkit.PoseLandmarkType.leftFootIndex,
      'right_foot_index' => mlkit.PoseLandmarkType.rightFootIndex,
      _ => null,
    };

/// Google ML Kit Pose Detection, running fully on-device.
class MlKitPoseEngine implements FramePoseEngine {
  MlKitPoseEngine({required this.topology});

  final LandmarkTopology topology;
  mlkit.PoseDetector? _detector;
  bool _initialised = false;

  @override
  String get engineId => 'mlkit_pose_blazepose_33';

  @override
  bool get isSynthetic => false;

  @override
  Future<void> initialize() async {
    if (_initialised) return;
    try {
      _detector = mlkit.PoseDetector(
        options: mlkit.PoseDetectorOptions(
          // Stream mode keeps tracking state between frames, which materially
          // reduces landmark jitter on video. That matters clinically here: gait
          // step-time variability is measured directly from these landmarks, so
          // optical jitter would otherwise be recorded as patient variability.
          mode: mlkit.PoseDetectionMode.stream,
          model: mlkit.PoseDetectionModel.base,
        ),
      );
      _initialised = true;
    } catch (error) {
      throw PoseEngineException(
        'Could not start the on-device pose detector: $error',
      );
    }
  }

  @override
  Stream<PoseFrame> get frames => throw UnsupportedError(
        'MlKitPoseEngine is pull-based: the camera drives it through '
        'detectFrame(), so there is no independent frame stream.',
      );

  @override
  Future<PoseFrame> detectFrame({
    required List<int> bytes,
    required int width,
    required int height,
    required int rotationDegrees,
    required int timestampUs,
  }) async {
    await initialize();
    final detector = _detector;
    if (detector == null) {
      throw PoseEngineException('Pose detector is not available.');
    }

    final inputImage = mlkit.InputImage.fromBytes(
      bytes: Uint8List.fromList(bytes),
      metadata: mlkit.InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: _rotationFromDegrees(rotationDegrees),
        // The camera plugin hands us NV21 YUV frames on Android, which is ML
        // Kit's preferred format and avoids a conversion pass on every frame.
        format: mlkit.InputImageFormat.nv21,
        bytesPerRow: width,
      ),
    );

    final List<mlkit.Pose> poses;
    try {
      poses = await detector.processImage(inputImage);
    } catch (error) {
      throw PoseEngineException('Pose detection failed on this frame: $error');
    }

    if (poses.isEmpty) {
      // A frame containing no body still returns a frame, with zero likelihood
      // on every landmark. Emitting it (rather than null) lets the quality gate
      // report "nobody detected" instead of the caller inventing that state.
      return _emptyFrame(timestampUs);
    }

    final pose = poses.first;
    final landmarks = <PoseLandmark>[];
    for (final landmark in topology.landmarks) {
      final type = _mlKitTypeFor(landmark.key);
      final detected = type == null ? null : pose.landmarks[type];
      if (detected == null) {
        landmarks.add(PoseLandmark(
          key: landmark.key,
          x: 0,
          y: 0,
          likelihood: 0,
        ));
        continue;
      }
      // Normalising to 0..1 here keeps every downstream feature independent of
      // capture resolution, which is what makes a measurement comparable across
      // the range of phones this product actually runs on.
      landmarks.add(PoseLandmark(
        key: landmark.key,
        x: width == 0 ? 0 : (detected.x / width).clamp(0.0, 1.0).toDouble(),
        y: height == 0 ? 0 : (detected.y / height).clamp(0.0, 1.0).toDouble(),
        z: detected.z,
        likelihood: detected.likelihood.clamp(0.0, 1.0).toDouble(),
      ));
    }

    return PoseFrame(timestampUs: timestampUs, landmarks: landmarks);
  }

  PoseFrame _emptyFrame(int timestampUs) => PoseFrame(
        timestampUs: timestampUs,
        landmarks: topology.landmarks
            .map((l) => PoseLandmark(key: l.key, x: 0, y: 0, likelihood: 0))
            .toList(growable: false),
      );

  static mlkit.InputImageRotation _rotationFromDegrees(int degrees) {
    // Normalise arbitrary rotation values into the four ML Kit accepts.
    final normalised = ((degrees % 360) + 360) % 360;
    return switch (normalised) {
      90 => mlkit.InputImageRotation.rotation90deg,
      180 => mlkit.InputImageRotation.rotation180deg,
      270 => mlkit.InputImageRotation.rotation270deg,
      _ => mlkit.InputImageRotation.rotation0deg,
    };
  }

  @override
  Future<void> dispose() async {
    await _detector?.close();
    _detector = null;
    _initialised = false;
  }
}
