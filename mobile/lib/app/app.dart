// Root application widget.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'router.dart';
import 'strings.dart';
import 'theme.dart';

class ArogyaApp extends ConsumerWidget {
  const ArogyaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(languageProvider);
    final strings = AppStrings(language);
    final router = ref.watch(routerProvider);

    return StringsScope(
      language: language,
      strings: strings,
      child: MaterialApp.router(
        title: 'Arogya-NER',
        debugShowCheckedModeBanner: false,
        theme: ArogyaTheme.light(),
        darkTheme: ArogyaTheme.dark(),
        routerConfig: router,
        // The interface scales with the system font size; PRD §19.3 asks for
        // readable typography, and clamping the scaler would defeat that on the
        // devices most likely to need it.
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.6,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
