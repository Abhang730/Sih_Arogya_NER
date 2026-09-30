// Types shared by every platform implementation of the local store.
//
// These live outside the platform files so that a caller can talk about the
// database handle and its security posture without importing dart:io or any
// plugin. That is what keeps the web build compiling.

import 'package:sqflite_common/sqlite_api.dart';

/// How the local database was actually opened.
///
/// This is not a preference or a setting: it is the measured state of the open
/// handle, which is why it is returned from [OpenedDatabase] rather than read
/// from configuration somewhere else.
enum DatabaseSecurity {
  /// SQLCipher, with the key held in platform secure storage (PRD §21.2).
  encryptedSqlcipher,

  /// Plain SQLite. Only reachable on platforms with no SQLCipher
  /// implementation, and only for development. PRD §21.2 requires encryption at
  /// rest for patient data, so a build running in this state is NOT
  /// field-deployable and must say so.
  unencryptedDevelopmentFallback;

  bool get isEncrypted => this == DatabaseSecurity.encryptedSqlcipher;

  /// Worker-facing statement of what this store does and does not protect.
  String get description => switch (this) {
        DatabaseSecurity.encryptedSqlcipher =>
          'Local records are encrypted on this device.',
        DatabaseSecurity.unencryptedDevelopmentFallback =>
          'Local records are NOT encrypted on this platform. SQLCipher has no '
              'implementation here. This build is for development only and must '
              'not be used with real patient data.',
      };
}

/// An open database plus the posture it was opened with.
class OpenedDatabase {
  const OpenedDatabase({
    required this.database,
    required this.security,
    required this.path,
    this.notes = const [],
  });

  final Database database;
  final DatabaseSecurity security;
  final String path;

  /// Anything the operator needs to know about this specific open, e.g. that a
  /// development key file was created.
  final List<String> notes;

  Future<void> close() => database.close();
}
