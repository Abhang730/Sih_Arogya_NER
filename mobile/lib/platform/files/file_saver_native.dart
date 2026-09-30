// Android/iOS implementation: write into the app's private documents directory.
//
// The file lands under app-private storage rather than in a shared or
// world-readable folder, because a report carries a patient identifier and
// clinical findings (PRD §25.2). Sharing is an explicit action by the worker,
// not a side effect of generating the file.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Writes [bytes] to `<documents>/reports/<fileName>` and returns the path.
///
/// Throws if the platform reports a directory but refuses to let the app write
/// into it — a silent failure here would record a report whose file is missing.
Future<String?> saveBytesToDocuments({
  required List<int> bytes,
  required String fileName,
}) async {
  final documents = await getApplicationDocumentsDirectory();
  final directory = Directory(p.join(documents.path, 'reports'));
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  final file = File(p.join(directory.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
