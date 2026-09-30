// Guards the protocol asset mirror.
//
// protocols/ at the repository root is the single source of truth. Flutter can
// only bundle assets that live inside the package directory, so the tree is
// mirrored into mobile/assets/protocols by tools/sync_protocols.py.
//
// The mirror is committed (so a fresh clone runs without extra setup), which
// means it CAN drift. This test is what makes drift impossible to merge: edit
// protocols/ without re-running the sync tool and this fails.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  // flutter test runs with the package root (mobile/) as the working directory.
  final source = Directory(p.join('..', 'protocols'));
  final mirror = Directory(p.join('assets', 'protocols'));

  test('the repository-root protocols directory exists', () {
    expect(source.existsSync(), isTrue,
        reason: 'expected the canonical protocols at ${source.absolute.path}');
  });

  test('the asset mirror exists (run: python tools/sync_protocols.py)', () {
    expect(mirror.existsSync(), isTrue,
        reason: 'run "python tools/sync_protocols.py" from the repository root');
  });

  test('every mirrored file is byte-identical to its source', () {
    expect(source.existsSync() && mirror.existsSync(), isTrue);

    final sourceFiles = source
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    expect(sourceFiles, isNotEmpty, reason: 'no protocol JSON found at the source');

    final stale = <String>[];
    for (final file in sourceFiles) {
      final rel = p.relative(file.path, from: source.path);
      final mirrored = File(p.join(mirror.path, rel));
      if (!mirrored.existsSync()) {
        stale.add('$rel (missing from the mirror)');
        continue;
      }
      if (file.readAsStringSync() != mirrored.readAsStringSync()) {
        stale.add('$rel (content differs)');
      }
    }

    expect(
      stale,
      isEmpty,
      reason: 'protocol assets have drifted from the source of truth:\n'
          '${stale.join('\n')}\n'
          'Run "python tools/sync_protocols.py" to resynchronise.',
    );
  });

  test('the mirror contains nothing that is not at the source', () {
    expect(source.existsSync() && mirror.existsSync(), isTrue);

    final orphans = <String>[];
    for (final file in mirror.listSync(recursive: true).whereType<File>()) {
      final rel = p.relative(file.path, from: mirror.path);
      if (!File(p.join(source.path, rel)).existsSync()) {
        orphans.add(rel);
      }
    }

    expect(orphans, isEmpty,
        reason: 'mirror holds files absent from the source: ${orphans.join(', ')}');
  });

  test('the protocol schema and landmark core are both bundled', () {
    expect(File(p.join(mirror.path, 'schema', 'joint_protocol.schema.json')).existsSync(), isTrue);
    expect(File(p.join(mirror.path, 'core', 'landmarks.json')).existsSync(), isTrue);
    expect(File(p.join(mirror.path, 'index.json')).existsSync(), isTrue);
  });
}
