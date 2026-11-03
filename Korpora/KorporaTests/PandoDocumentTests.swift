import Cocoa
import ManateeKit
import PandoKit
import Testing
@testable import Korpora

/// `ConcordanceDocument` driven by a real pando index through `PandoEngine`.
/// Needs KORPORA_PANDO_LIB (a libpando.dylib with pando-index beside it; run
/// with `TEST_RUNNER_KORPORA_PANDO_LIB=... xcodebuild test`); skipped without.
@MainActor @Suite(.serialized) struct PandoDocumentTests {
    private static let conllu = """
        # sent_id = s1
        1\tthe\tthe\tDET\t_\t_\t2\tdet\t_\t_
        2\tcat\tcat\tNOUN\t_\t_\t3\tnsubj\t_\t_
        3\teats\teat\tVERB\t_\t_\t0\troot\t_\t_
        4\tfish\tfish\tNOUN\t_\t_\t3\tobj\t_\t_

        # sent_id = s2
        1\ta\ta\tDET\t_\t_\t2\tdet\t_\t_
        2\tdog\tdog\tNOUN\t_\t_\t3\tnsubj\t_\t_
        3\teats\teat\tVERB\t_\t_\t0\troot\t_\t_
        4\tmeat\tmeat\tNOUN\t_\t_\t3\tobj\t_\t_


        """

    private func makeEngine() throws -> (PandoEngine, URL)? {
        guard let path = ProcessInfo.processInfo.environment["KORPORA_PANDO_LIB"],
              let library = try? PandoLibrary(path: path) else { return nil }
        let tool = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pando-index")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PandoDocumentTests-\(UUID().uuidString)")
        let input = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Self.conllu.write(to: input.appendingPathComponent("t.conllu"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = tool
        process.arguments = [input.path, root.appendingPathComponent("tiny").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (PandoEngine(library: library, corporaRoot: root), root)
    }

    private func settle(_ document: ConcordanceDocument) async {
        for _ in 0..<2500 where document.isSearching { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func aDocumentSearchesAPandoCorpus() async throws {
        guard let (engine, root) = try makeEngine() else { return }  // no pando build: nothing to test
        defer { try? FileManager.default.removeItem(at: root) }
        let document = ConcordanceDocument()
        document.engine = engine
        document.corpusName = "tiny"
        document.historyDefaults = UserDefaults(suiteName: "PandoDocumentTests-\(UUID().uuidString)")!
        document.runQuery(#"[upos="NOUN" & deprel="obj"]"#)
        await settle(document)
        #expect(document.rows.map { $0.line.kwic }.sorted() == ["fish", "meat"], "\(document.status)")
        #expect(document.status.hasPrefix("2 hits"), "\(document.status)")

        // Analyses go through the same document API as for Manatee.
        let items = try await document.frequencyDistribution([FrequencyCriterion(attribute: "lemma")])
        #expect(Set(items.map(\.word)) == ["fish", "meat"])
        let collocates = try await document.collocations(
            CollocationSpec(attribute: "lemma", leftWindow: -2, rightWindow: 2, minFrequency: 1, minCollocateFrequency: 1))
        #expect(collocates.contains { $0.word == "eat" })
    }

    @Test func anUnsupportedOperationShowsAClearMessageInTheStatus() async throws {
        guard let (engine, root) = try makeEngine() else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let document = ConcordanceDocument()
        document.engine = engine
        document.corpusName = "tiny"
        document.historyDefaults = UserDefaults(suiteName: "PandoDocumentTests-\(UUID().uuidString)")!
        document.runQuery("[]")
        await settle(document)
        document.performShuffle()
        await settle(document)
        #expect(document.status.contains("Shuffling"), "\(document.status)")
    }
}
