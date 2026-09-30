// Native (Android/iOS) model runner.
//
// This is a thin wrapper around tflite_flutter, kept in one file so that the
// `dart:ffi` dependency appears exactly once in the codebase and the rest of the
// app talks about a model runner, not about a native library.

import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart' as tfl;

class TfliteInterpreter {
  TfliteInterpreter._(this._interpreter)
      : _inputShape = _interpreter.getInputTensor(0).shape,
        _outputShape = _interpreter.getOutputTensor(0).shape;

  final tfl.Interpreter _interpreter;
  final List<int> _inputShape;
  final List<int> _outputShape;

  static bool get isSupported => true;

  /// Loads a model from bundled bytes, or null when the artefact cannot be
  /// loaded. Null is returned rather than thrown because a missing optional
  /// artefact must degrade one branch, not fail the screening.
  static Future<TfliteInterpreter?> load(Uint8List bytes) async {
    try {
      return TfliteInterpreter._(tfl.Interpreter.fromBuffer(bytes));
    } catch (_) {
      return null;
    }
  }

  /// Runs one inference and returns the first output value.
  ///
  /// Supports the two shapes the training pipeline emits — `[1, n]` and `[n]` —
  /// because an exported model that disagrees with this wrapper would otherwise
  /// fail at run time in a worker's hands instead of at build time.
  double run(List<double> vector) {
    final input = _inputShape.length == 2
        ? [List<double>.from(vector)]
        : List<double>.from(vector);

    if (_outputShape.length == 2) {
      final output = [List<double>.filled(_outputShape[1], 0)];
      _interpreter.run(input, output);
      return output.first.first;
    }

    final output = List<double>.filled(_outputShape.first, 0);
    _interpreter.run(input, output);
    return output.first;
  }

  void close() => _interpreter.close();
}
