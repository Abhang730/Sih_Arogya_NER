// Statistics helpers for feature extraction.
//
// Kept dependency-free and pure so the feature pipeline is trivially testable
// and produces identical numbers on-device, in Python during training, and in
// tests. Any divergence between the training-time and on-device feature code is
// a silent, serious bug class (train/serve skew), so the arithmetic here is
// deliberately simple and explicit.

import 'dart:math' as math;

class Stats {
  const Stats._();

  static double mean(List<double> values) {
    if (values.isEmpty) return double.nan;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  /// Sample standard deviation (n-1). Returns 0 for fewer than two values.
  static double stdev(List<double> values) {
    if (values.length < 2) return 0;
    final m = mean(values);
    var sumSq = 0.0;
    for (final v in values) {
      final d = v - m;
      sumSq += d * d;
    }
    return math.sqrt(sumSq / (values.length - 1));
  }

  /// Coefficient of variation. Guards the zero-mean case rather than emitting
  /// infinity, which would then poison a model input.
  static double cv(List<double> values) {
    final m = mean(values);
    if (m == 0 || m.isNaN) return 0;
    return stdev(values) / m.abs();
  }

  static double min(List<double> values) =>
      values.isEmpty ? double.nan : values.reduce(math.min);

  static double max(List<double> values) =>
      values.isEmpty ? double.nan : values.reduce(math.max);

  static double range(List<double> values) {
    if (values.isEmpty) return double.nan;
    return max(values) - min(values);
  }

  static double median(List<double> values) {
    if (values.isEmpty) return double.nan;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// Mean absolute first difference — a simple smoothness/jerk proxy that needs
  /// no sampling-rate term, so it stays comparable across capture rates.
  static double meanAbsDiff(List<double> values) {
    if (values.length < 2) return 0;
    var sum = 0.0;
    for (var i = 1; i < values.length; i++) {
      sum += (values[i] - values[i - 1]).abs();
    }
    return sum / (values.length - 1);
  }

  static double sum(List<double> values) {
    var total = 0.0;
    for (final v in values) {
      total += v;
    }
    return total;
  }

  /// Asymmetry between paired sides.
  ///
  /// Returns a bounded 0..1 ratio where 0 is perfectly symmetric. Using the
  /// symmetric formulation (|a-b| / (a+b)) instead of a simple difference keeps
  /// the value scale-free, so a fast patient and a slow patient with the same
  /// relative asymmetry score the same.
  static double asymmetryIndex(double a, double b) {
    final denominator = a.abs() + b.abs();
    if (denominator == 0) return 0;
    return ((a - b).abs() / denominator).clamp(0.0, 1.0).toDouble();
  }
}

/// Fixed-size ring buffer for streaming capture.
///
/// Screening captures are bounded (a few seconds at ~30 fps), so the buffer
/// prevents an unattended or buggy capture loop from growing without limit on a
/// low-memory device.
class RingBuffer<T> {
  RingBuffer(this.capacity)
      : assert(capacity > 0, 'capacity must be positive'),
        _items = <T>[];

  final int capacity;
  final List<T> _items;

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  bool get isFull => _items.length >= capacity;

  List<T> get items => List<T>.unmodifiable(_items);

  /// Adds [item], discarding the oldest entry once [capacity] is reached.
  void add(T item) {
    if (_items.length >= capacity) {
      _items.removeAt(0);
    }
    _items.add(item);
  }

  void clear() => _items.clear();
}
