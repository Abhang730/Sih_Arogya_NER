// Shared presentational widgets.
//
// Kept in one place so that the two presentation rules the PRD makes binding are
// enforced by construction rather than re-implemented per screen:
//
//   * PRD §19.2: risk state is never conveyed by colour alone — [RiskChip]
//     always renders an icon and a word.
//   * PRD §19.2: "never hide a failed quality check" — [MessageCard] with
//     severity.error is visually distinct and cannot be dismissed the way an
//     informational card can.

import 'package:flutter/material.dart';

import '../../app/strings.dart';
import '../../app/theme.dart';

/// Labelled section used by every screening screen (PRD §19.2 "clear NEXT").
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.35,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Severity of a message, which decides whether it may be dismissed.
enum MessageSeverity { info, warning, error, success }

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.message,
    this.severity = MessageSeverity.info,
    this.title,
  });

  final String message;
  final MessageSeverity severity;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (severity) {
      MessageSeverity.info => (Icons.info_outline, const Color(0xFF00696D)),
      MessageSeverity.warning => (Icons.warning_amber_rounded, const Color(0xFFE65100)),
      MessageSeverity.error => (Icons.error_outline, const Color(0xFFB71C1C)),
      MessageSeverity.success => (Icons.check_circle_outline, const Color(0xFF1B5E20)),
    };

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 3),
                ],
                Text(
                  message,
                  style: const TextStyle(fontSize: 13.5, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Risk state, always with an icon and a word (PRD §19.2).
class RiskChip extends StatelessWidget {
  const RiskChip({
    super.key,
    required this.presentation,
    this.dense = false,
  });

  final RiskPresentation presentation;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 4 : 7,
      ),
      decoration: BoxDecoration(
        color: presentation.color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(presentation.icon, size: dense ? 14 : 17, color: presentation.onColor),
          const SizedBox(width: 6),
          Text(
            presentation.label,
            style: TextStyle(
              color: presentation.onColor,
              fontSize: dense ? 12 : 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Standard loading state.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(message!, textAlign: TextAlign.center),
            ],
          ],
        ),
      );
}

/// Standard error state, with a retry action.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Color(0xFFB71C1C)),
            const SizedBox(height: 14),
            const Text(
              'Something went wrong on this device.',
              style: TextStyle(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: onRetry,
                child: Text(context.s('action.retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A labelled measurement, with an explicit "not measured" rendering.
///
/// A null value renders as "not measured" rather than as 0, which is the
/// presentation half of the rule that a missing measurement is never a zero
/// (PRD §26.5).
class MeasurementTile extends StatelessWidget {
  const MeasurementTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.caveat,
  });

  final String label;
  final double? value;
  final String? unit;
  final String? caveat;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(fontSize: 14.5))),
              Text(
                value == null
                    ? 'not measured'
                    : '${_format(value!)}${unit == null ? '' : ' $unit'}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: value == null ? scheme.onSurfaceVariant : scheme.onSurface,
                  fontStyle: value == null ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ],
          ),
          if (caveat != null) ...[
            const SizedBox(height: 2),
            Text(
              caveat!,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  static String _format(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

