// Motion Pod entry point.
//
// BLE is Android/iOS only, so the conditional export keeps the web build free
// of the BLE plugin while still giving it a working simulated session.

export 'pod_stub.dart'
    if (dart.library.io) 'pod_native.dart'
    show createMotionPodSession, hasRealPodTransport, podUnavailableReason;

export 'pod_types.dart';
