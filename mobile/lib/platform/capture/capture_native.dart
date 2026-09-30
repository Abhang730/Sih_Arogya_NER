// Native capture: real camera + ML Kit on Android/iOS, synthetic elsewhere.
//
// This file is the only place in the app that talks to the `camera` plugin. It
// sits behind [PoseCapture] so no screen depends on it (the same boundary
// DECISIONS.md D1 draws around ML Kit).
//
// Two implementation details are worth stating because they are easy to get
// subtly wrong and hard to notice:
//
//   * Frame-to-frame format. MlKitPoseEngine asks for NV21 with
//     bytesPerRow == width, so the YUV420 planes from the camera have to be
//     packed into a contiguous NV21 buffer. Getting the plane strides wrong
//     produces a pose that looks plausible but is skewed, which would corrupt
//     every angle downstream.
//   * Self-throttling. Pose detection is the expensive step, and a low-end
//     phone cannot run it at the camera's frame rate. Instead of dropping
//     arbitrary frames on a timer, a frame is only submitted when no detection
//     is in flight. The delivered frame rate is then whatever the device can
//     actually sustain, and the feature extractor — which uses real timestamps,
//     not a nominal fps — stays correct.
//
// The capture screen is portrait-locked, which is what makes the rotation
// handling below deterministic rather than a matrix of device orientations.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../domain/protocol/models.dart';
import '../../pose/mlkit_pose_engine.dart';
import '../../pose/pose_types.dart';
import '../../pose/synthetic_pose_engine.dart';
import 'capture_types.dart';

bool get hasRealPoseEngine => Platform.isAndroid || Platform.isIOS;

String get poseEngineUnavailableReason =>
    'No camera pose engine is available on ${Platform.operatingSystem}. ML Kit '
    'Pose Detection runs only on Android and iOS (DECISIONS.md D1).';

/// Creates the best available capture for this platform.
Future<PoseCapture> createPoseCapture({
  required LandmarkTopology topology,
  SyntheticMotion motion = SyntheticMotion.walking,
  double durationSeconds = 6,
  int fps = 30,
}) async {
  if (hasRealPoseEngine) {
    // A PoseEngineException here propagates on purpose. Quietly substituting
    // the synthetic engine when a real camera failed would put generated
    // landmarks on screen during a real screening, which is precisely the
    // fabrication PRD §1.2 forbids. The screen catches it and asks the worker
    // to retry instead.
    return await CameraPoseCapture.create(topology: topology);
  }
  return SyntheticPoseCapture(
    topology: topology,
    motion: motion,
    durationSeconds: durationSeconds,
    fps: fps,
  );
}

/// Real camera capture, with pose detection on each frame.
class CameraPoseCapture implements PoseCapture {
  CameraPoseCapture._({
    required this.topology,
    required this._controller,
    required this._engine,
  });

  final LandmarkTopology topology;
  final CameraController _controller;
  final MlKitPoseEngine _engine;

  final StreamController<PoseFrame> _frames = StreamController<PoseFrame>.broadcast();

  /// Mean frame brightness in 0..1 from the Y plane, for the quality gate's
  /// lighting check (PRD §9.4). Null until a frame has been measured — the gate
  /// reports "not measured" rather than passing on a fabricated value.
  @override
  double? get meanLuma => _lastMeanLuma;
  double? _lastMeanLuma;

  /// True while a detection is in flight, used to self-throttle.
  bool _busy = false;
  bool _streaming = false;

  static Future<CameraPoseCapture> create({required LandmarkTopology topology}) async {
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } catch (error) {
      throw PoseEngineException('No camera is available on this device: $error');
    }
    if (cameras.isEmpty) {
      throw PoseEngineException('No camera is available on this device.');
    }

    // Prefer the back camera: the movement protocol is filmed by a second
    // person or on a stand, and the back camera has the better sensor.
    final description = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await controller.initialize();
    } catch (error) {
      throw PoseEngineException('Camera initialisation failed: $error');
    }

    final engine = MlKitPoseEngine(topology: topology);
    await engine.initialize();

    return CameraPoseCapture._(
      topology: topology,
      controller: controller,
      engine: engine,
    );
  }

  @override
  String get engineId => _engine.engineId;

  @override
  bool get isSynthetic => false;

  @override
  bool get hasLivePreview => _controller.value.isInitialized;

  @override
  Stream<PoseFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    if (_streaming) return;
    _streaming = true;
    await _controller.startImageStream(_onImage);
  }

  @override
  Future<void> stop() async {
    if (!_streaming) return;
    _streaming = false;
    try {
      await _controller.stopImageStream();
    } catch (_) {
      // A camera torn down by the OS mid-capture throws here; there is nothing
      // useful to do about it and the caller is already stopping.
    }
    await _frames.close();
  }

  Future<void> _onImage(CameraImage image) async {
    // Self-throttling: skip frames while a detection is running rather than
    // queueing them. A queue would grow without bound on a slow device and the
    // frames would arrive too late to be useful.
    if (_busy || _frames.isClosed) return;
    _busy = true;

    try {
      final nv21 = _toNv21(image);
      _lastMeanLuma = _meanLuma(image);

      final frame = await _engine.detectFrame(
        bytes: nv21,
        width: image.width,
        height: image.height,
        rotationDegrees: _rotationDegrees(),
        timestampUs: DateTime.now().microsecondsSinceEpoch,
      );
      if (!_frames.isClosed) _frames.add(frame);
    } catch (_) {
      // A single failed frame is not a failed capture. The stream simply
      // produces one fewer frame, and the quality gate still sees the rest.
    } finally {
      _busy = false;
    }
  }

  /// The capture screen is portrait-locked, so rotation reduces to the camera
  /// sensor's own orientation.
  int _rotationDegrees() {
    final sensor = _controller.description.sensorOrientation;
    return _controller.description.lensDirection == CameraLensDirection.front
        ? (360 - sensor) % 360
        : sensor;
  }

  /// Packs YUV420 planes into the contiguous NV21 buffer ML Kit expects.
  ///
  /// Deliberately reads `bytesPerRow` and `pixelStride` from the planes rather
  /// than assuming them: devices differ, and a wrong assumption yields a skewed
  /// pose rather than an error.
  static Uint8List _toNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;

    // Some devices deliver a single interleaved plane, which is already in a
    // layout ML Kit accepts.
    if (image.planes.length == 1) {
      return Uint8List.fromList(image.planes.first.bytes);
    }

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final nv21 = Uint8List(width * height + (width * height ~/ 2));

    var offset = 0;
    for (var row = 0; row < height; row++) {
      final rowStart = row * yPlane.bytesPerRow;
      // setRange copies `width` bytes starting at skipCount = rowStart, which
      // is exactly one padded row from the Y plane into the contiguous buffer.
      nv21.setRange(offset, offset + width, yPlane.bytes, rowStart);
      offset += width;
    }

    // The chroma planes are subsampled by two in both axes. `bytesPerPixel` is
    // the distance between adjacent samples within a row, and it is nullable in
    // the plugin's API, so a device that does not report it falls back to the
    // tightly-packed assumption of 1.
    final uvStride = uPlane.bytesPerPixel ?? 1;
    final uvHeight = height ~/ 2;
    final uvWidth = width ~/ 2;
    for (var row = 0; row < uvHeight; row++) {
      final uvRowStart = row * uPlane.bytesPerRow;
      for (var col = 0; col < uvWidth; col++) {
        final uvIndex = uvRowStart + col * uvStride;
        if (uvIndex >= vPlane.bytes.length || uvIndex >= uPlane.bytes.length) {
          break;
        }
        // NV21 is V then U.
        nv21[offset++] = vPlane.bytes[uvIndex];
        nv21[offset++] = uPlane.bytes[uvIndex];
      }
    }

    return nv21;
  }

  /// Mean luma in 0..1 from the Y plane, sampled every 16th pixel.
  ///
  /// Sampling rather than averaging the whole plane is a deliberate trade: this
  /// runs on the capture path on a low-end device, and a lighting threshold does
  /// not need exact arithmetic.
  static double _meanLuma(CameraImage image) {
    final bytes = image.planes.first.bytes;
    if (bytes.isEmpty) return 0;

    var sum = 0;
    var count = 0;
    const stride = 16;
    for (var i = 0; i < bytes.length; i += stride) {
      sum += bytes[i];
      count++;
    }
    return count == 0 ? 0 : (sum / count) / 255.0;
  }

  @override
  Widget buildPreview(BuildContext context) =>
      _controller.value.isInitialized ? CameraPreview(_controller) : const SizedBox.shrink();

  /// Releases the camera and the pose detector. Called when a capture session
  /// ends, because both hold native resources that would otherwise accumulate
  /// across patients.
  Future<void> dispose() async {
    await stop();
    await _engine.dispose();
    await _controller.dispose();
  }
}
