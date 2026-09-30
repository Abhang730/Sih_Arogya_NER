// Pose capture boundary (PRD §9.3, §10.1, §19.1).
//
// Screens talk to [PoseCapture], never to the camera plugin or to ML Kit. Two
// implementations exist:
//
//   * a real camera + ML Kit capture, on Android and iOS;
//   * a synthetic capture, everywhere else.
//
// The synthetic one is not a stub that fails politely. It is the same
// SyntheticPoseEngine the repository already ships for exactly this purpose
// (DECISIONS.md D1 anticipated web/desktop having no real pose engine), and it
// produces geometrically valid landmark sequences. What matters is that its
// output is never mistaken for a measurement: [isSynthetic] is true, the engine
// id is recorded on every stored assessment, and the capture screen renders a
// non-dismissible notice while it is in use.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../pose/pose_types.dart';
import '../../pose/synthetic_pose_engine.dart';

/// A source of pose frames for one movement test.
abstract class PoseCapture {
  /// Human-readable engine name, stored with the assessment for traceability
  /// (PRD §27.2).
  String get engineId;

  /// True when frames are generated, not measured. Callers MUST surface this.
  bool get isSynthetic;

  /// Whether a live camera image can be shown behind the landmark overlay.
  bool get hasLivePreview;

  /// Mean frame brightness in 0..1 from the most recent camera frame, or null
  /// when this capture has no camera image (the synthetic engine).
  ///
  /// The quality gate needs to distinguish "no image at all" from "no image
  /// yet": the first makes the lighting check impossible, the second makes it
  /// pending, and treating either as a failure blocks a working capture.
  double? get meanLuma;

  /// Starts capture. Safe to call more than once.
  Future<void> start();

  /// Stops capture and releases resources.
  Future<void> stop();

  /// Pose frames in capture order.
  Stream<PoseFrame> get frames;

  /// Optional live camera view. A synthetic capture has no camera to show, so
  /// this returns a placeholder that says so rather than an empty black box.
  Widget buildPreview(BuildContext context);
}

/// Synthetic capture, backed by [SyntheticPoseEngine].
///
/// Replays a pre-computed, geometrically consistent landmark sequence in real
/// time. Used on web and desktop, and in tests, where no camera pose engine
/// exists.
class SyntheticPoseCapture implements PoseCapture {
  SyntheticPoseCapture({
    required this.topology,
    this.motion = SyntheticMotion.walking,
    this.durationSeconds = 6,
    this.fps = 30,
  }) : _engine = SyntheticPoseEngine(
          topology: topology,
          motion: motion,
          durationSeconds: durationSeconds,
          fps: fps,
        );

  final dynamic topology;
  final SyntheticMotion motion;
  final double durationSeconds;
  final int fps;

  final SyntheticPoseEngine _engine;

  @override
  String get engineId => _engine.engineId;

  @override
  bool get isSynthetic => true;

  @override
  bool get hasLivePreview => false;

  /// Always null: generated landmarks come from no image, so there is no
  /// brightness to measure. Reported rather than fabricated.
  @override
  double? get meanLuma => null;

  @override
  Stream<PoseFrame> get frames => _engine.frames;

  @override
  Future<void> start() async {
    await _engine.initialize();
    _engine.start();
  }

  @override
  Future<void> stop() async {
    await _engine.dispose();
  }

  @override
  Widget buildPreview(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off_outlined,
                  size: 44, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                'No camera pose engine on this device',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'A simulated body is being screened so the workflow can be '
                'demonstrated. The landmarks are generated, not measured.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
