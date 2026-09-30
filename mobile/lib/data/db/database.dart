// Local encrypted storage (PRD §21.2, §25.1).
//
// PRD §21.2 recommends SQLite protected with SQLCipher, with keys held in
// platform secure storage. That is what the mobile build does:
// sqflite_sqlcipher opens the database with a key that lives in
// flutter_secure_storage, so a phone pulled out of a worker's bag yields an
// encrypted blob rather than a patient list.
//
// The problem this file has to solve honestly: SQLCipher has no Windows, Linux,
// macOS or web implementation, and this project is developed and tested on a
// Windows host. Two unacceptable options were available — refuse to run outside
// Android/iOS at all, or quietly open a plaintext database and let everyone
// assume it is encrypted. The second is the dangerous one, because "it worked
// on my machine" would look identical to a correct run.
//
// So the fallback exists, is selected by platform, and is NAMED for what it is.
// [OpenedDatabase.security] reports the actual posture every time, and Settings
// renders a permanent warning while the store is unencrypted.
//
// Platform selection lives behind a conditional import so that importing
// dart:io never breaks a web build, and so no mobile-only plugin is pulled into
// the web dependency graph.
//
// The web branch is a real SQLite database (sqlite3/WASM) rather than a stub, so
// the demonstration build exercises the same schema and the same queries. It
// reports itself as unencrypted, because SQLCipher has no browser implementation
// and pretending otherwise is the one failure mode that matters here.

import 'db_stub.dart'
    if (dart.library.io) 'db_native.dart'
    if (dart.library.js_interop) 'db_web.dart' as impl;
import 'db_types.dart';

export 'db_types.dart';

/// Opens (creating if needed) the local Arogya-NER database.
///
/// Returns the database together with the security posture it was actually
/// opened with, so a caller cannot hold the handle without also being able to
/// see whether it is encrypted.
Future<OpenedDatabase> openArogyaDatabase({
  String? directoryOverride,
  String? passphraseOverride,
  bool allowUnencryptedFallback = true,
}) =>
    impl.openArogyaDatabase(
      directoryOverride: directoryOverride,
      passphraseOverride: passphraseOverride,
      allowUnencryptedFallback: allowUnencryptedFallback,
    );
