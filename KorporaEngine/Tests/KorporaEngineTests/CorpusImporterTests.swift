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
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.corpora.path).filter { $0.hasPrefix(".importing") }
        XCTAssertEqual(leftovers, [])
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
