import Cocoa

/// CoNLL-U files dropped on the app icon (or opened with "Open With"): they start the same import as the
/// Import button in Settings > Corpora, with the files already chosen. Nothing temporary is made; the
/// import sheet names the corpus and adds it to the library.
///
/// AppKit hands every dropped file to `KorporaDocumentController.openDocument(withContentsOf:...)` one at a
/// time, so they are collected for a moment and imported as one corpus (several files make one corpus,
/// as with the Import button).
@MainActor
enum ConlluDrop {
    /// The extension of the files accepted (declared in Info.plist as a document type).
    static let fileExtension = "conllu"

    static func isConllu(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    /// What happens with the collected files. Replaced in tests, which have no window to present a sheet on.
    static var handler: ([URL]) -> Void = { urls in
        SettingsWindowController.shared.show(.corpora)
        (SettingsWindowController.shared.window?.contentViewController as? CorporaSettingsViewController)?
            .importCorpus(from: urls)
    }

    private static var pending: [URL] = []

    /// Takes a dropped file; the files that arrive together are imported together.
    static func add(_ url: URL) {
        pending.append(url)
        guard pending.count == 1 else { return }
        DispatchQueue.main.async {
            let urls = pending.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            pending = []
            handler(urls)
        }
    }
}
