// Web implementation: there is no application documents directory.
//
// Returning null rather than a plausible-looking fake path is the point. The
// report screen passes the PDF to the browser's print/share dialog, which is the
// only durable destination the platform offers, and records it as generated
// rather than as stored.

/// Returns the path the bytes were written to, or null when this platform has
/// nowhere to write them.
Future<String?> saveBytesToDocuments({
  required List<int> bytes,
  required String fileName,
}) async =>
    null;
