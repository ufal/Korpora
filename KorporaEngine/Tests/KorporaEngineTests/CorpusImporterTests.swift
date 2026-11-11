import Foundation
import XCTest
@testable import KorporaEngine

final class CorpusImporterTests: XCTestCase {
    private func tool() throws -> URL {
        _ = try TestPando.library()
        let path = try XCTUnwrap(TestPando.libraryPath)
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pando-index")
    }

    private func write(_ text: String, as name: String, in box: TestPando.Sandbox) throws -> URL {
        let url = box.root.appendingPathComponent("in/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testKindIsDecidedByExtension() {
        XCTAssertEqual(CorpusImporter.kind(of: [URL(fileURLWithPath: "/x/a.conllu")]), .conllu)
        XCTAssertEqual(CorpusImporter.kind(of: [URL(fileURLWithPath: "/x/a.vrt")]), .vertical)
        XCTAssertEqual(CorpusImporter.kind(of: [URL(fileURLWithPath: "/x/a.VERT")]), .vertical)
        XCTAssertEqual(CorpusImporter.kind(of: [URL(fileURLWithPath: "/x/a.jsonl")]), .jsonl)
        XCTAssertEqual(CorpusImporter.kind(of: [URL(fileURLWithPath: "/x/folder")]), .conllu)
    }

    func testImportsAFileIntoTheLibraryAndReportsProgress() async throws {
        let tool = try tool()
        let box = try TestPando.Sandbox()
        let file = try write(TestPando.tinyConllu, as: "tiny.conllu", in: box)
        let seen = Seen()
        let destination = try await CorpusImporter.importCorpus(name: "Tiny", inputs: [file], tool: tool) { seen.add($0) }

        XCTAssertEqual(destination.lastPathComponent, "Tiny")
        XCTAssertEqual(CorpusLibrary.names(), ["Tiny"])
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, 8)
        XCTAssertTrue(seen.all.contains { $0.phase == .reading && $0.fraction == 1 }, "\(seen.all.map(\.line))")
        XCTAssertEqual(seen.all.compactMap { $0.tokens > 0 ? $0.tokens : nil }.last, 8)
        XCTAssertTrue(seen.all.contains { $0.phase == .finishing })
        // No leftovers of the temporary folder.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.corpora.path)
        XCTAssertEqual(leftovers.filter { $0 != "Tiny" }, [], "no \"Unfinished Work\" folder either")
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasPrefix(".") }, "and nothing hidden")
    }

    func testSeveralFilesBecomeOneCorpus() async throws {
        let tool = try tool()
        let box = try TestPando.Sandbox()
        let a = try write(TestPando.tinyConllu, as: "a.conllu", in: box)
        let b = try write(TestPando.tinyConllu, as: "b.conllu", in: box)
        let seen = Seen()
        try await CorpusImporter.importCorpus(name: "Both", inputs: [a, b], tool: tool) { seen.add($0) }
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, 16)
        XCTAssertEqual(seen.all.compactMap(\.fraction).max(), 1)
        XCTAssertTrue(seen.all.contains { $0.fraction == 0.5 })
    }

    func testAFolderOfTreebanksBecomesOneCorpus() async throws {
        let tool = try tool()
        let box = try TestPando.Sandbox()
        _ = try write(TestPando.tinyConllu, as: "UD_One/one.conllu", in: box)
        _ = try write(TestPando.tinyConllu, as: "UD_Two/two.conllu", in: box)
        try await CorpusImporter.importCorpus(name: "Folder", inputs: [box.root.appendingPathComponent("in")], tool: tool)
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, 16)
    }

    func testANameThatIsTakenIsRefusedBeforeAnyWork() async throws {
        let tool = try tool()
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "Taken", in: box.corpora)
        let file = try write(TestPando.tinyConllu, as: "t.conllu", in: box)
        do {
            try await CorpusImporter.importCorpus(name: "Taken", inputs: [file], tool: tool)
            XCTFail("expected an error")
        } catch let error as CorpusImportError {
            XCTAssertEqual("\(error)", "A corpus named \u{201C}Taken\u{201D} is already in Korpora.")
        }
        // A linked corpus holds its name too.
        let outside = try box.fakeIndex(named: "Linked one", in: box.elsewhere)
        try CorpusLibrary.link(indexDirectory: outside, taken: [])
        do {
            try await CorpusImporter.importCorpus(name: "Linked one", inputs: [file], tool: tool)
            XCTFail("expected an error")
        } catch is CorpusImportError {}
    }

    func testNothingToImportAndMissingToolAreClearErrors() async throws {
        let box = try TestPando.Sandbox()
        _ = box
        do {
            try await CorpusImporter.importCorpus(name: "X", inputs: [], tool: URL(fileURLWithPath: "/nonexistent"))
            XCTFail("expected an error")
        } catch let error as CorpusImportError { XCTAssertTrue("\(error)".contains("nothing to import")) }
    }

    func testAFailedIndexLeavesNoCorpusAndShowsTheToolsOutput() async throws {
        let tool = try tool()
        let box = try TestPando.Sandbox()
        let missing = box.root.appendingPathComponent("no-such-file.conllu")
        do {
            try await CorpusImporter.importCorpus(name: "Broken", inputs: [missing], tool: tool)
            XCTFail("expected an error")
        } catch let error as CorpusImportError {
            guard case .failed(let log) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(log.isEmpty)
        }
        XCTAssertEqual(CorpusLibrary.names(), [])
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: box.corpora.path)) ?? []
        XCTAssertEqual(leftovers.filter { !$0.hasPrefix(".") || $0.hasPrefix(".importing") }, [])
    }

    /// A stand-in for pando-index that prints one progress line and then sleeps, so the cancel
    /// always lands while the tool is running.
    private func sleepingTool(in box: TestPando.Sandbox) throws -> URL {
        let script = box.root.appendingPathComponent("slow-tool.sh")
        try "#!/bin/sh\necho '[1/2] /x/a.conllu  (10 tok, 1 ktok/s)'\nexec sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testCancellingStopsTheToolAndLeavesNothing() async throws {
        let box = try TestPando.Sandbox()
        let tool = try sleepingTool(in: box)
        let file = try write(TestPando.tinyConllu, as: "t.conllu", in: box)
        let seen = Seen()
        let started = Date()
        let task = Task { try await CorpusImporter.importCorpus(name: "Slow", inputs: [file], tool: tool) { seen.add($0) } }
        // Wait until the tool is demonstrably running (its progress line arrived).
        for _ in 0..<200 where !seen.all.contains(where: { $0.fraction == 0.5 }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(seen.all.contains { $0.fraction == 0.5 }, "the tool never reported progress")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the tool was not stopped")
        XCTAssertEqual(CorpusLibrary.names(), [])
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: box.corpora.path)) ?? [])
            .filter { !$0.hasPrefix(".") || $0.hasPrefix(".importing") }
        XCTAssertEqual(leftovers, [])
    }

    func testAToolThatFailsReportsItsLastOutput() async throws {
        let box = try TestPando.Sandbox()
        let script = box.root.appendingPathComponent("bad-tool.sh")
        try "#!/bin/sh\necho 'Error: the input is not CoNLL-U'\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let file = try write(TestPando.tinyConllu, as: "t.conllu", in: box)
        do {
            try await CorpusImporter.importCorpus(name: "Bad", inputs: [file], tool: script)
            XCTFail("expected an error")
        } catch let error as CorpusImportError {
            XCTAssertTrue("\(error)".contains("the input is not CoNLL-U"), "\(error)")
        }
        XCTAssertEqual(CorpusLibrary.names(), [])
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [CorpusImporter.Progress] = []
    func add(_ p: CorpusImporter.Progress) { lock.lock(); list.append(p); lock.unlock() }
    var all: [CorpusImporter.Progress] { lock.lock(); defer { lock.unlock() }; return list }
}

final class UDMetadataTests: XCTestCase {
    func testTheLanguageAndTheTreebankComeFromTheFileName() {
        XCTAssertEqual(UDMetadata.parse(fileName: "cs_pdt-ud-train.conllu")?.language, "cs")
        XCTAssertEqual(UDMetadata.parse(fileName: "cs_pdt-ud-train.conllu")?.treebank, "pdt")
        XCTAssertEqual(UDMetadata.parse(fileName: "gsw_UZH-ud-test.conllu")?.treebank, "uzh")
        XCTAssertEqual(UDMetadata.parse(fileName: "zh_gsdsimp-ud-dev.conllu")?.language, "zh")
        XCTAssertEqual(UDMetadata.parse(fileName: "yue_hk-ud-test.conllu")?.treebank, "hk")
        for name in ["tiny.conllu", "cs_pdt.conllu", "pdt-ud-train.conllu", "_x-ud-test.conllu", "cs_-ud-test.conllu", "cs_pdt-ud-train.txt"] {
            XCTAssertNil(UDMetadata.parse(fileName: name), name)
        }
        XCTAssertEqual(UDMetadata.header(forFileName: "en_ewt-ud-dev.conllu"), """
            # newregion text
            # text_id = en_ewt-ud-dev.conllu
            # text_lang = English
            # text_lang_family = Indo-European
            # text_lang_genus = Germanic
            # text_lang_iso3 = eng
            # text_lang_script = Latn
            # text_langcode = en
            # text_treebank = ewt

            """.replacingOccurrences(of: "\n\n", with: "\n"))
        // A language UD's table doesn't have: only what the file name says (pando pads the rest with `_`).
        XCTAssertEqual(UDMetadata.header(forFileName: "qqq_x-ud-dev.conllu"),
                       "# newregion text\n# text_id = qqq_x-ud-dev.conllu\n# text_langcode = qqq\n# text_treebank = x\n")
        // No branch given: no line for it (Abkhaz is a family of its own in the table).
        XCTAssertFalse(try XCTUnwrap(UDMetadata.header(forFileName: "ab_abnc-ud-test.conllu")).contains("text_lang_genus"))
        XCTAssertTrue(try XCTUnwrap(UDMetadata.header(forFileName: "cs_pdt-ud-dev.conllu")).contains("# text_lang_genus = Slavic\n"))
    }

    func testEveryLanguageOfTheTableHasItsFieldsAndCodesAreLowerCase() {
        XCTAssertGreaterThan(UDLanguages.byCode.count, 280)
        for (code, entry) in UDLanguages.byCode {
            XCTAssertEqual(code, code.lowercased())
            XCTAssertFalse(entry.name.isEmpty, code)
            XCTAssertFalse(entry.iso3.isEmpty, code)
            XCTAssertFalse(entry.family.isEmpty, code)
            XCTAssertFalse(entry.scripts.isEmpty, code)
            for script in entry.scripts { XCTAssertEqual(script.count, 4, code) }
        }
        XCTAssertEqual(UDLanguages.byCode["cs"]?.family, "Indo-European", "UD's \"IE\" is written out")
    }

    private func write(_ text: String, as name: String, in box: TestPando.Sandbox) throws -> URL {
        let url = box.root.appendingPathComponent("in/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAFileThatAlreadyOpensATextRegionIsLeftAlone() throws {
        let box = try TestPando.Sandbox()
        let prepared = try write("# newregion text\n# text_id = x\n" + TestPando.tinyConllu, as: "cs_pdt-ud-train.conllu", in: box)
        let plain = try write(TestPando.tinyConllu, as: "en_ewt-ud-dev.conllu", in: box)
        XCTAssertTrue(UDMetadata.hasTextHeader(prepared))
        XCTAssertFalse(UDMetadata.hasTextHeader(plain))
        XCTAssertFalse(UDMetadata.needsHeaders([prepared]))
        XCTAssertTrue(UDMetadata.needsHeaders([prepared, plain]))
    }

    private func tool() throws -> URL {
        _ = try TestPando.library()
        let path = try XCTUnwrap(TestPando.libraryPath)
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pando-index")
    }

    func testImportingUDFilesGivesTextAttributesAndLeavesTheFilesAlone() async throws {
        let tool = try tool()
        let box = try TestPando.Sandbox()
        let cs = try write(TestPando.tinyConllu, as: "UD_Czech-PDT/cs_pdt-ud-train.conllu", in: box)
        let en = try write(TestPando.tinyConllu, as: "UD_English-EWT/en_ewt-ud-dev.conllu", in: box)
        let before = try Data(contentsOf: cs)
        let folder = box.root.appendingPathComponent("in")
        try await CorpusImporter.importCorpus(name: "UD", inputs: [folder], tool: tool)

        XCTAssertEqual(try Data(contentsOf: cs), before, "the user's file is not changed")
        XCTAssertFalse(try String(contentsOf: en, encoding: .utf8).contains("newregion"))
        let engine = PandoEngine(library: try TestPando.library())
        let corpus = try await engine.openCorpus(name: "UD")
        let codes = try await corpus.attributeValues(attribute: "text.langcode")
        let treebanks = try await corpus.attributeValues(attribute: "text.treebank")
        let ids = try await corpus.attributeValues(attribute: "text.id")
        XCTAssertEqual(codes, ["cs", "en"])
        XCTAssertEqual(treebanks, ["ewt", "pdt"])
        XCTAssertEqual(ids, ["cs_pdt-ud-train.conllu", "en_ewt-ud-dev.conllu"])
        // What UD's language table adds.
        let names = try await corpus.attributeValues(attribute: "text.lang")
        let families = try await corpus.attributeValues(attribute: "text.lang_family")
        let genera = try await corpus.attributeValues(attribute: "text.lang_genus")
        let scripts = try await corpus.attributeValues(attribute: "text.lang_script")
        let iso = try await corpus.attributeValues(attribute: "text.lang_iso3")
        XCTAssertEqual(names, ["Czech", "English"])
        XCTAssertEqual(families, ["Indo-European"])
        XCTAssertEqual(genera, ["Germanic", "Slavic"])
        XCTAssertEqual(scripts, ["Latn"])
        XCTAssertEqual(iso, ["ces", "eng"])
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, 16)
        // The point of it: a search or a subcorpus by branch, family or script.
        func hits(_ restriction: String) async throws -> Int {
            try await engine.openConcordance(query: "[upos=\"NOUN\"] :: \(restriction)", in: corpus).totalHits
        }
        let slavic = try await hits("match.text_lang_genus = \"Slavic\"")
        let germanic = try await hits("match.text_lang_genus = \"Germanic\"")
        let indoEuropean = try await hits("match.text_lang_family = \"Indo-European\"")
        let latin = try await hits("match.text_lang_script = \"Latn\"")
        let cyrillic = try await hits("match.text_lang_script = \"Cyrl\"")
        XCTAssertEqual([slavic, germanic, indoEuropean, latin, cyrillic], [4, 4, 8, 8, 0])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.corpora.path)
        XCTAssertEqual(leftovers, ["UD"], "the staged copies are gone")
    }

    func testALanguageWrittenInTwoScriptsIsFoundByEither() async throws {
        let tool = try tool()
        let box = try TestPando.Sandbox()
        _ = try write(TestPando.tinyConllu, as: "ro_rrt-ud-dev.conllu", in: box)     // Latn, Cyrl
        _ = try write(TestPando.tinyConllu, as: "bg_btb-ud-dev.conllu", in: box)     // Cyrl
        _ = try write(TestPando.tinyConllu, as: "qqq_x-ud-dev.conllu", in: box)      // not in the table
        try await CorpusImporter.importCorpus(name: "Scripts", inputs: [box.root.appendingPathComponent("in")], tool: tool)
        let engine = PandoEngine(library: try TestPando.library())
        let corpus = try await engine.openCorpus(name: "Scripts")
        let scripts = try await corpus.attributeValues(attribute: "text.lang_script")
        XCTAssertEqual(scripts.filter { $0 != "_" }, ["Cyrl", "Latn"], "the values are listed one by one: \(scripts)")
        func nouns(_ script: String) async throws -> Int {
            try await engine.openConcordance(query: "[upos=\"NOUN\"] :: match.text_lang_script = /\(script)/", in: corpus).totalHits
        }
        let cyrillic = try await nouns("Cyrl")
        let latin = try await nouns("Latn")
        XCTAssertEqual([cyrillic, latin], [8, 4], "Romanian counts for both, Bulgarian for Cyrillic only")
    }

    func testFilesWithOtherNamesAreImportedAsBefore() async throws {
        let tool = try tool()
        let box = try TestPando.Sandbox()
        let file = try write(TestPando.tinyConllu, as: "tiny.conllu", in: box)
        try await CorpusImporter.importCorpus(name: "Tiny", inputs: [file], tool: tool)
        let engine = PandoEngine(library: try TestPando.library())
        let values = try? await engine.openCorpus(name: "Tiny").attributeValues(attribute: "text.langcode")
        XCTAssertTrue(values == nil || values == [] || values == ["_"], "no language invented: \(String(describing: values))")
    }
}
