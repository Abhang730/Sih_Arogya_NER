// Where a generated report is written, if it can be written at all.
//
// A generated PDF has two audiences: the worker, who hands a printed or shared
// copy to the patient, and the record, which should keep a copy with the
// screening. On Android and iOS both are possible. On the web there is no
// writable application documents directory, so the honest answer is that no
// file was stored — the caller then records the report without claiming a path
// that does not exist (PRD §26.5: an unmeasured thing is never reported as
// measured).

export 'file_saver_stub.dart'
    if (dart.library.io) 'file_saver_native.dart'
    show saveBytesToDocuments;
