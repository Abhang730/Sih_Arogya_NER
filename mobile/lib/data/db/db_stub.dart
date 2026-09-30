// Non-native (web) implementation of the local store.
//
// There is no encrypted local database on the web target, and there is also no
// field use case for one: PRD §18.1 puts the offline workflow on an Android
// device. Rather than pretend, this throws.
//
// It is reachable only when dart.library.io is absent, which is the web build.

import 'db_types.dart';

/// Always throws on platforms without a native SQLite implementation.
Future<OpenedDatabase> openArogyaDatabase({
  String? directoryOverride,
  String? passphraseOverride,
  bool allowUnencryptedFallback = true,
}) {
  throw UnsupportedError(
    'Arogya-NER has no local database on this platform. The offline screening '
    'workflow (PRD §18.1) requires the Android or iOS build, where records are '
    'stored in an encrypted SQLCipher database. The web build is a UI preview '
    'only and does not persist patient data.',
  );
}
