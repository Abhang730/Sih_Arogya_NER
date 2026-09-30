// The screening-not-diagnosis boundary (PRD §1.2, §24.1, §28 FR-25).
//
// PRD §28 FR-25 requires the notice "at result/report boundaries". The way to
// satisfy that without relying on a developer remembering is to make the
// boundary widgets the ONLY way to render a result or a report header, which is
// what [SafetyBanner] and [SafetyFooter] are for.
//
// The text comes from [ClinicalStrings], not from interface strings, because
// §20.2 requires clinical wording to be versioned independently — and the
// disclaimer is the single most clinical string in the product.

import 'package:flutter/material.dart';

import 'strings.dart';

/// Compact notice shown above a result or report.
class SafetyBanner extends StatelessWidget {
  const SafetyBanner({super.key, this.dense = false});

  /// Dense form for embedding inside an already-labelled section.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = ClinicalStrings.lookup(
          'disclaimer',
          StringsScope.of(context).language.code,
          'text',
        ) ??
        context.s('safety.detail');

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(dense ? 10 : 14),
      decoration: BoxDecoration(
        // Outline rather than a solid fill: a full-width red block on every
        // result screen trains people to ignore it, which is the opposite of
        // what a binding safety notice needs.
        border: Border.all(color: scheme.outline, width: 1.2),
        borderRadius: BorderRadius.circular(12),
        color: scheme.surfaceContainerHighest,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: scheme.primary, size: dense ? 18 : 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.s('safety.banner'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: dense ? 14 : 16,
                  ),
                ),
                if (!dense) ...[
                  const SizedBox(height: 6),
                  Text(text, style: const TextStyle(fontSize: 14, height: 1.35)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full disclaimer for the foot of a report or the end of a result screen.
class SafetyFooter extends StatelessWidget {
  const SafetyFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final text = ClinicalStrings.lookup(
          'disclaimer',
          StringsScope.of(context).language.code,
          'text',
        ) ??
        context.s('safety.detail');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(
          text,
          style: const TextStyle(fontSize: 12.5, height: 1.4),
        ),
      ],
    );
  }
}

/// Labels output that came from a synthetic engine rather than the patient.
///
/// PRD §1.2 forbids fabricated clinical claims. A demo or desktop build that
/// falls back to the synthetic pose engine is producing generated data, and the
/// screen has to say so — otherwise a plausible-looking landmark overlay would
/// read as a measurement of the person standing in front of the phone.
class SyntheticDataNotice extends StatelessWidget {
  const SyntheticDataNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE7F6),
        border: Border.all(color: const Color(0xFF4527A0)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.science_outlined, color: Color(0xFF4527A0), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.35,
                color: scheme.brightness == Brightness.dark
                    ? Colors.white
                    : const Color(0xFF311B92),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
