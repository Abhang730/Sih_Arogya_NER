// Native (Android/iOS/desktop) implementation of the local store.
//
// PRD §21.2's reference design is SQLite + SQLCipher with the key in platform
// secure storage. The mobile branch below implements exactly that. The desktop
// branch exists because this project is developed and tested on Windows, where
// SQLCipher has no implementation, and it is deliberately loud about not being
// encrypted rather than quietly substituting plain SQLite.

import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'db_types.dart';
import 'schema.dart';

const String _databaseFileName = 'arogya_ner.db';
const String _keyStorageName = 'arogya_ner.db.key';

/// Platforms where SQLCipher is implemented.
bool get _isMobile => Platform.isAndroid || Platform.isIOS;

Future<OpenedDatabase> openArogyaDatabase({
  String? directoryOverride,
  String? passphraseOverride,
  bool allowUnencryptedFallback = true,
}) async {
  final directory = directoryOverride ?? await _applicationDirectory();
  final path = '$directory/$_databaseFileName';

  if (_isMobile) {
    return _openEncrypted(path, passphraseOverride);
  }

  if (!allowUnencryptedFallback) {
    throw UnsupportedError(
      'No SQLCipher implementation exists on this platform, and '
      'allowUnencryptedFallback was false, so the local store cannot be opened. '
      'Run the mobile build for encrypted storage (PRD §21.2).',
    );
  }
  return _openDevelopmentDatabase(path, directoryOverride);
}

// ── Encrypted (mobile) ────────────────────────────────────────────────────

Future<OpenedDatabase> _openEncrypted(String path, String? passphraseOverride) async {
  final passphrase = passphraseOverride ?? await _persistentKey();

  final database = await sqlcipher.openDatabase(
    path,
    password: passphrase,
    version: ArogyaSchema.version,
    onCreate: (db, version) => _createSchema(db),
    onConfigure: (db) async {
      // Off by default in SQLite and easy to leave on. Without this, a child
      // row can be written pointing at a parent that does not exist.
      await db.execute('PRAGMA foreign_keys = ON');
    },
  );

  return OpenedDatabase(
    database: database,
    security: DatabaseSecurity.encryptedSqlcipher,
    path: path,
  );
}

/// Reads the database key from platform secure storage, generating one on first
/// run.
///
/// The key is NEVER derived from the worker's passcode. Deriving it would mean a
/// passcode change made the stored records unreadable, and it would let anyone
/// who learned the passcode open the database offline.
Future<String> _persistentKey() async {
  const storage = FlutterSecureStorage();
  final existing = await storage.read(key: _keyStorageName);
  if (existing != null && existing.length >= 32) return existing;

  final generated = _randomKey();
  await storage.write(key: _keyStorageName, value: generated);
  return generated;
}

String _randomKey() {
  // 32 bytes of a cryptographically seeded generator, hex-encoded. Not using a
  // UUID: a UUIDv4 carries only 122 bits and this key protects the whole store.
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ── Unencrypted (development desktop) ─────────────────────────────────────

Future<OpenedDatabase> _openDevelopmentDatabase(
  String path,
  String? directoryOverride,
) async {
  ffi.sqfliteFfiInit();
  final factory = ffi.databaseFactoryFfi;

  final database = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: ArogyaSchema.version,
      onCreate: (db, version) => _createSchema(db),
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );

  return OpenedDatabase(
    database: database,
    security: DatabaseSecurity.unencryptedDevelopmentFallback,
    path: path,
    notes: [
      'Opened with sqflite_common_ffi instead of SQLCipher because '
      '${Platform.operatingSystem} has no SQLCipher implementation.',
      'Do not enter real patient data in this build (PRD §21.2, §25.1).',
    ],
  );
}

// ── Shared ────────────────────────────────────────────────────────────────

Future<String> _applicationDirectory() async {
  final base = await getApplicationDocumentsDirectory();
  final path = '${base.path}/arogya_ner';
  final dir = Directory(path);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return path;
}

Future<void> _createSchema(Database db) async {
  final batch = db.batch();
  for (final statement in ArogyaSchema.createStatements) {
    batch.execute(statement);
  }
  await batch.commit(noResult: true);
}
