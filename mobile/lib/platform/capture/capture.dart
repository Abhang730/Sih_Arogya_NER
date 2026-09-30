// Capture entry point.
//
// The real implementation pulls in the camera plugin and ML Kit, neither of
// which exists on the web. The conditional export selects the web factory there
// so a web build still compiles and still runs — with the synthetic engine,
// clearly labelled.
//
//     import 'platform/capture/capture.dart';

export 'capture_stub.dart'
    if (dart.library.io) 'capture_native.dart'
    show createPoseCapture, hasRealPoseEngine, poseEngineUnavailableReason;

export 'capture_types.dart';
