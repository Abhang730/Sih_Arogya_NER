// Web Motion Pod factory.
//
// BLE is not available on the web target in any form this app can use, and the
// ESP32-S3 firmware does not exist yet, so this returns the simulated session.
// It is explicitly labelled by the caller rather than pretending to have paired.

import 'pod_types.dart';

/// Whether real Motion Pod hardware can be reached on this platform.
bool get hasRealPodTransport => false;

/// Why no real pod transport is available.
String get podUnavailableReason =>
    'The web build cannot reach the Motion Pod over BLE, and the ESP32-S3 '
    'firmware is not built yet (see README implementation status).';

/// Creates a session for the given placements.
Future<MotionPodSession> createMotionPodSession({
  required List<PodPlacement> placements,
}) async =>
    SimulatedMotionPodSession(placements: placements);
