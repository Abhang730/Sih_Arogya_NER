// Existing imaging and reports (PRD §16, §28 FR-15).
//
// PRD §16 is unusually clear about scope, and this screen is built to match it
// rather than to look impressive:
//
//   * §16.2 — imaging is SUPPORTING EVIDENCE. The app does not interpret it. A
//     dedicated imaging branch becomes possible only when a validated model
//     exists for a specific modality and joint (§16.3), and when it does it will
//     enter fusion as an optional fourth branch, never as a silent replacement
//     for the field measurements.
//   * §34 — a phone camera cannot read an X-ray film or perform ultrasound, so
//     what is attached is a photograph of an existing report or film, taken by
//     the worker, and it is labelled as such.
//
// The attachment is therefore recorded as evidence with its provenance, not
// fed into any model.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../app/safety.dart';
import '../../app/strings.dart';
import '../../data/records.dart';
import '../../data/repositories.dart';
import '../widgets/common.dart';

/// What kind of evidence is being attached. Recorded so the specialist knows
/// what they are looking at without opening the file.
class _EvidenceKind {
  const _EvidenceKind(this.wire, this.label);

  final String wire;
  final String label;

  static const List<_EvidenceKind> values = [
    _EvidenceKind('xray', 'X-ray film or report'),
    _EvidenceKind('ultrasound', 'Ultrasound report'),
    _EvidenceKind('mri_ct', 'MRI or CT report'),
    _EvidenceKind('clinical_report', 'Clinical / specialist note'),
    _EvidenceKind('photograph', 'Photograph of the affected joint'),
  ];
}

class ImagingScreen extends ConsumerStatefulWidget {
  const ImagingScreen({super.key});

  @override
  ConsumerState<ImagingScreen> createState() => _ImagingScreenState();
}

class _ImagingScreenState extends ConsumerState<ImagingScreen> {
  final ImagePicker _picker = ImagePicker();

  List<AttachmentRecord>? _attachments;
  _EvidenceKind _kind = _EvidenceKind.values.first;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final screeningId = ref.read(screeningSessionProvider).screening?.screeningId;
    if (screeningId == null) {
      setState(() => _attachments = const []);
      return;
    }
    try {
      final repos = await ref.read(repositoriesProvider.future);
      final attachments = await repos.screenings.attachmentsFor(screeningId);
      if (!mounted) return;
      setState(() => _attachments = attachments);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _pick(ImageSource source) async {
    final session = ref.read(screeningSessionProvider);
    final screeningId = session.screening?.screeningId;

    if (screeningId == null) {
      setState(() => _error =
          'This screening has not been saved yet, so nothing can be attached.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final picked = await _picker.pickImage(
        source: source,
        // Downscaled deliberately: an X-ray photographed with a 12 MP sensor is
        // several megabytes, and this file is stored on a phone in a village,
        // not in a hospital PACS.
        maxWidth: 2000,
        imageQuality: 85,
      );
      if (picked == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      // Bytes are read to record a real size, and to fail loudly here if the
      // file cannot be read at all, rather than storing a path that points at
      // nothing.
      final bytes = await picked.readAsBytes();
      final repos = await ref.read(repositoriesProvider.future);
      final attachmentId = newId('att');

      await repos.screenings.saveAttachment(
        AttachmentRecord(
          attachmentId: attachmentId,
          screeningId: screeningId,
          kind: _kind.wire,
          localPath: picked.path,
          mimeType: picked.mimeType ?? _mimeFor(picked.path),
          byteSize: bytes.length,
          capturedAt: nowIso(),
          // Attachments are supporting evidence and are uploaded with the
          // screening only when consent allows the record to sync (FR-05).
          syncState: session.patient?.consentGiven ?? false
              ? SyncState.pending
              : SyncState.localOnly,
        ),
      );

      await repos.audit.record(
        action: 'attachment.added',
        actor: ref.read(authProvider)?.workerId,
        recordId: attachmentId,
        entity: 'attachment',
        deviceMeta: {
          'kind': _kind.wire,
          'bytes': bytes.length,
          'source': source.name,
        },
      );

      ref.read(screeningSessionProvider.notifier).setImagingAttached(true);
      await _load();

      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  static String _mimeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'image/jpeg';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final attachments = _attachments;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('imaging.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          MessageCard(
            title: 'Supporting evidence only',
            message: s.t('imaging.role'),
          ),

          SectionCard(
            title: s.t('imaging.attach'),
            subtitle: 'Photograph an existing film or report, or choose an '
                'existing image from this device.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<_EvidenceKind>(
                  initialValue: _kind,
                  decoration: const InputDecoration(
                    labelText: 'What is this?',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final kind in _EvidenceKind.values)
                      DropdownMenuItem(value: kind, child: Text(kind.label)),
                  ],
                  onChanged: (value) =>
                      setState(() => _kind = value ?? _EvidenceKind.values.first),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _pick(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Photograph'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Choose file'),
                      ),
                    ),
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),

          if (_error != null)
            MessageCard(message: _error!, severity: MessageSeverity.error),

          SectionCard(
            title: 'Attached to this screening',
            subtitle: attachments == null
                ? null
                : '${attachments.length} attachment'
                    '${attachments.length == 1 ? '' : 's'}',
            child: attachments == null
                ? const Text('Reading attachments…')
                : attachments.isEmpty
                    ? Text(s.t('imaging.none'))
                    : Column(
                        children: [
                          for (final attachment in attachments)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                attachment.kind == 'photograph'
                                    ? Icons.image_outlined
                                    : Icons.description_outlined,
                              ),
                              title: Text(attachment.kind.replaceAll('_', ' ')),
                              subtitle: Text(
                                '${_bytes(attachment.byteSize)} · '
                                '${_short(attachment.capturedAt)}'
                                '${attachment.syncState == SyncState.localOnly ? ' · kept on this device only' : ''}',
                              ),
                            ),
                        ],
                      ),
          ),

          SectionCard(
            title: 'Imaging AI',
            child: Text(
              'No imaging model is bundled, and none is claimed. Automatic '
              'interpretation of arbitrary medical images is explicitly out of '
              'scope until a validated model exists for a specific modality and '
              'joint (PRD §16.3, §26.5).',
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => context.pop(),
            child: Text(s.t('action.save')),
          ),
          const SizedBox(height: 24),
          const SafetyBanner(dense: true),
        ],
      ),
    );
  }

  static String _bytes(int? size) {
    if (size == null) return 'size unknown';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} kB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _short(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
