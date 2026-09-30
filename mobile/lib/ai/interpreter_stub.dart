// Web implementation: no native TensorFlow Lite runtime, so no runner.
//
// Every method is present and every one either reports unavailability or throws.
// Nothing returns a plausible number, because a fabricated score is the exact
// failure this product's safety guardrails exist to prevent.

import 'dart:typed_data';

class TfliteInterpreter {
  TfliteInterpreter._();

  /// False on every platform without a TensorFlow Lite runtime.
  static bool get isSupported => false;

  /// Always null: there is no runtime to load a model into.
  static Future<TfliteInterpreter?> load(Uint8List bytes) async => null;

  /// Unreachable, because [load] never returns an instance. Throws rather than
  /// returning a default so a future refactor cannot silently turn this into a
  /// score.
  double run(List<double> vector) => throw UnsupportedError(
        'This build has no on-device model runtime, so no model can run. '
        'The measurement is reported as unavailable, never as a value.',
      );

  void close() {}
}
