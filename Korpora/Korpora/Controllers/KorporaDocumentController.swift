import Cocoa

/// Installed as `NSDocumentController.shared` (see `main.swift`). The default
/// `NSDocumentController` behavior already suffices for creating a new
/// `ConcordanceDocument` (it's the only declared document type) - the
/// "ask for a corpus + CQL query first" sheet is triggered from
/// `ConcordanceDocument.makeWindowControllers()` instead, since AppKit's
/// automatic untitled-document-at-launch path calls
/// `openUntitledDocumentAndDisplay(false)` and shows the window itself
/// through a separate path, not through this override.
///
/// CoNLL-U files are declared as a document type so that they can be dropped on the app icon, but they are not
/// documents: they start the corpus import instead (`ConlluDrop`).
final class KorporaDocumentController: NSDocumentController {
    override func openDocument(
        withContentsOf url: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        guard ConlluDrop.isConllu(url) else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }
        ConlluDrop.add(url)
        completionHandler(nil, false, nil)
    }
}
