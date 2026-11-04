import Cocoa
import Testing
@testable import Korpora

/// CoNLL-U files dropped on the app icon start the corpus import (they are not opened as documents).
@MainActor @Suite(.serialized) struct ConlluDropTests {
    private func collecting(_ body: () async -> Void) async -> [[URL]] {
        let original = ConlluDrop.handler
        var batches: [[URL]] = []
        ConlluDrop.handler = { batches.append($0) }
        defer { ConlluDrop.handler = original }
        await body()
        // The files are collected for one run-loop turn.
        try? await Task.sleep(nanoseconds: 100_000_000)
        return batches
    }

    @Test func onlyConlluFilesAreAccepted() {
        #expect(ConlluDrop.isConllu(URL(fileURLWithPath: "/tmp/a.conllu")))
        #expect(ConlluDrop.isConllu(URL(fileURLWithPath: "/tmp/A.CONLLU")))
        #expect(!ConlluDrop.isConllu(URL(fileURLWithPath: "/tmp/a.vrt")))
        #expect(!ConlluDrop.isConllu(URL(fileURLWithPath: "/tmp/a.corpconc")))
        #expect(!ConlluDrop.isConllu(URL(string: "https://example.org/a.conllu")!))
    }

    @Test func aDroppedFileStartsTheImportInsteadOfOpeningADocument() async {
        let url = URL(fileURLWithPath: "/tmp/dropped.conllu")
        var opened: (NSDocument?, Bool, Error?)?
        let batches = await collecting {
            KorporaDocumentController().openDocument(withContentsOf: url, display: true) { opened = ($0, $1, $2) }
        }
        #expect(batches == [[url]])
        #expect(opened != nil && opened?.0 == nil && opened?.2 == nil, "no document and no error alert")
    }

    @Test func filesDroppedTogetherAreImportedTogetherInNameOrder() async {
        let urls = ["b10", "b2", "a1"].map { URL(fileURLWithPath: "/tmp/\($0).conllu") }
        let batches = await collecting {
            let controller = KorporaDocumentController()
            for url in urls { controller.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
        }
        #expect(batches.count == 1)
        #expect(batches.first?.map(\.lastPathComponent) == ["a1.conllu", "b2.conllu", "b10.conllu"])
    }

    @Test func otherFilesStillOpenAsDocuments() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nothing-\(UUID().uuidString).corpconc")
        let batches = await collecting {
            await withCheckedContinuation { continuation in
                KorporaDocumentController().openDocument(withContentsOf: url, display: false) { _, _, _ in continuation.resume() }
            }
        }
        #expect(batches.isEmpty)
    }

    @Test func theAppDeclaresConlluAsADocumentType() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let declared = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        #expect(declared.contains("org.universaldependencies.conllu"))
        let imported = try #require(Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        let tags = imported.compactMap { $0["UTTypeTagSpecification"] as? [String: Any] }
            .flatMap { $0["public.filename-extension"] as? [String] ?? [] }
        #expect(tags.contains("conllu"))
    }
}
