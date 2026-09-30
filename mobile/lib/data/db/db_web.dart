// Browser (web) implementation of the local store.
//
// The web build exists to DEMONSTRATE the workflow — a reviewer clicks a link
// and walks the whole screening path. That requires a working store, because a
// screening that cannot be saved is not the product.
//
// What it deliberately is not:
//
//   * It is NOT SQLCipher. SQLCipher has no browser implementation, so the
//     store reports [DatabaseSecurity.unencryptedDevelopmentFallback] and the
//     Settings screen says in plain words that this build must not hold real
//     patient data. The alternative — a web build that quietly behaved like the
//     encrypted one — would be the dangerous kind of convenient.
//   * It is NOT the same storage engine as the field app beyond the SQL layer:
//     sqlite3 (compiled to WebAssembly) runs inside a web worker and persists
//     through the browser's own storage. That is a genuine SQLite database with
//     the SAME schema, created from the same [ArogyaSchema.createStatements],
//     so the demo exercises the real queries rather than a mock.
//
// Everything the app stores on the web lives in the reviewer's own browser and
// nowhere else. Nothing is uploaded.

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'db_types.dart';
import 'schema.dart';

const String _databaseFileName = 'arogya_ner_demo.db';

Future<OpenedDatabase> openArogyaDatabase({
  String? directoryOverride,
  String? passphraseOverride,
  bool allowUnencryptedFallback = true,
}) async {
  // The name is fixed rather than random so that a reload during a demo keeps
  // the records the reviewer created, instead of appearing to lose them.
  final factory = databaseFactoryFfiWeb;

  final database = await factory.openDatabase(
    _databaseFileName,
    options: OpenDatabaseOptions(
      version: ArogyaSchema.version,
      onCreate: (db, version) => _createSchema(db),
      onConfigure: (db) async {
        // Off by default in SQLite, and the schema relies on it to keep a child
        // row from pointing at a parent that does not exist.
        await db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );

  return OpenedDatabase(
    database: database,
    security: DatabaseSecurity.unencryptedDevelopmentFallback,
    path: '$_databaseFileName (browser storage, not encrypted)',
    notes: [
      'This is the web demonstration build. Records are stored in this browser '
      'only and are not encrypted at rest.',
      'Do not enter real patient data here (PRD §21.2, §25.1).',
    ],
  );
}

Future<void> _createSchema(Database db) async {
  final batch = db.batch();
  for (final statement in ArogyaSchema.createStatements) {
    batch.execute(statement);
  }
  await batch.commit(noResult: true);
}
