// Arogya-NER — application entry point.
//
// Screening, not diagnosis. See docs/DECISIONS.md for every deliberate
// deviation from the PRD and why.
//
// The previous contents of this file were the untouched Flutter counter
// template; the engines under lib/ai, lib/pose and lib/wearable were built and
// tested but nothing rendered them. This is the wiring that makes the app the
// product rather than a library with a test suite.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: ArogyaApp()));
}
