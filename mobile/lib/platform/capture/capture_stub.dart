// Web capture factory.
//
// The web target has no camera pose engine: ML Kit is Android/iOS only. Rather
// than present a broken camera button, this returns the synthetic capture, which
// works everywhere and labels itself.

import '../../domain/protocol/models.dart';
import '../../pose/synthetic_pose_engine.dart';
import 'capture_types.dart';

/// Returns a synthetic capture. There is no real pose engine on this platform.
Future<PoseCapture> createPoseCapture({
  required LandmarkTopology topology,
  SyntheticMotion motion = SyntheticMotion.walking,
  double durationSeconds = 6,
  int fps = 30,
}) async =>
    SyntheticPoseCapture(
      topology: topology,
      motion: motion,
      durationSeconds: durationSeconds,
      fps: fps,
    );

/// Whether a real (non-synthetic) pose engine is available on this platform.
bool get hasRealPoseEngine => false;

/// Why a real engine is unavailable, for display in the UI.
String get poseEngineUnavailableReason =>
    'The web build has no on-device pose engine. ML Kit Pose Detection runs '
    'only on Android and iOS (DECISIONS.md D1).';
