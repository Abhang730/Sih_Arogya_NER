// The on-device model runner, abstracted by platform.
//
// tflite_flutter is a `dart:ffi` package: it binds to the TensorFlow Lite C
// library, which exists on Android and iOS and does not exist in a browser. That
// is not a reason to drop the web build, and it is certainly not a reason to
// pretend a model ran — so the runner sits behind a conditional import and
// reports itself as unavailable where it cannot run.
//
// What the caller sees is [TfliteInterpreter.isSupported] plus a null from
// [TfliteInterpreter.load]. A branch that cannot run therefore returns
// BranchUnavailableReason.platformUnsupported, which the result screen and the
// report render as "this measurement was not taken on this build" rather than
// as a score of zero (PRD §26.5).

export 'interpreter_stub.dart'
    if (dart.library.ffi) 'interpreter_native.dart'
    show TfliteInterpreter;
