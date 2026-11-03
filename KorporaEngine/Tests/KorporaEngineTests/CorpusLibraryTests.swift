import Foundation
import XCTest
@testable import KorporaEngine

final class CorpusLibraryTests: XCTestCase {
    func testListsBuiltThenLinkedCorporaWithTheirSizes() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "beta", in: box.corpora, tokens: 2_000)
        try box.fakeIndex(named: "alpha", in: box.corpora, tokens: 1_000)
        let outside = try box.fakeIndex(named: "gamma", in: box.elsewhere, tokens: 3)
        try CorpusLibrary.link(indexDirectory: outside, taken: [])

        let entries = CorpusLibrary.entries()
        XCTAssertEqual(entries.map(\.name), ["alpha", "beta", "gamma"])
        XCTAssertEqual(entries.map(\.tokens), [1_000, 2_000, 3])
        XCTAssertEqual(entries.map(\.isLinked), [false, false, true])
        XCTAssertEqual(CorpusLibrary.directory(forName: "gamma")?.lastPathComponent, "gamma")
        XCTAssertNil(CorpusLibrary.directory(forName: "nope"))
    }

    func testIgnoresFoldersThatAreNotCorporaAndHiddenOnes() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "real", in: box.corpora)
        try FileManager.default.createDirectory(at: box.corpora.appendingPathComponent("not-a-corpus"), withIntermediateDirectories: true)
        try box.fakeIndex(named: ".hidden", in: box.corpora)
        try box.fakeIndex(named: ".importing-x", in: box.corpora)
        XCTAssertEqual(CorpusLibrary.names(), ["real"])
    }

    func testNaturalOrderOfNames() throws {
        let box = try TestPando.Sandbox()
        for name in ["UD 10", "UD 2", "UD 1"] { try box.fakeIndex(named: name, in: box.corpora) }
        XCTAssertEqual(CorpusLibrary.names(), ["UD 1", "UD 2", "UD 10"])
    }

    func testBuiltWinsWhenANameIsInBothPlaces() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "same", in: box.corpora, tokens: 1)
        let other = try box.fakeIndex(named: "same", in: box.elsewhere, tokens: 2)
        XCTAssertThrowsError(try CorpusLibrary.link(indexDirectory: other, taken: ["same"])) {
            XCTAssertEqual($0 as? CorpusLibrary.LibraryError, .nameTaken("same"))
        }
        XCTAssertEqual(CorpusLibrary.entries().map(\.tokens), [1])
    }

    func testLinkingRequiresAnIndex() throws {
        let box = try TestPando.Sandbox()
        let empty = box.elsewhere.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CorpusLibrary.link(indexDirectory: empty, taken: [])) {
            XCTAssertEqual($0 as? CorpusLibrary.LibraryError, .notACorpus(empty.resolvingSymlinksInPath()))
        }
    }

    func testLinkAllAddsEveryIndexInAFolderAndReportsTakenNames() throws {
        let box = try TestPando.Sandbox()
        for name in ["a", "b", "c"] { try box.fakeIndex(named: name, in: box.elsewhere) }
        let result = CorpusLibrary.linkAll(inDirectory: box.elsewhere, taken: ["b"])
        XCTAssertEqual(result.added.map(\.name), ["a", "c"])
        XCTAssertEqual(result.skipped.map(\.name), ["b"])
        XCTAssertEqual(CorpusLibrary.names(), ["a", "c"])
    }

    func testRemovingALinkedCorpusKeepsItsFolderUnlessAsked() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "far", in: box.elsewhere)
        var entry = try CorpusLibrary.link(indexDirectory: target, taken: [])
        try CorpusLibrary.remove(entry, deleteData: false)
        XCTAssertTrue(CorpusLibrary.names().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "data kept")

        entry = try CorpusLibrary.link(indexDirectory: target, taken: [])
        try CorpusLibrary.remove(entry, deleteData: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "data deleted")
    }

    func testRemovingABuiltCorpusMovesItAsideOrDeletesIt() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "mine", in: box.corpora)
        let kept = try CorpusLibrary.remove(try XCTUnwrap(CorpusLibrary.entries().first), deleteData: false)
        XCTAssertTrue(CorpusLibrary.names().isEmpty)
        XCTAssertTrue(CorpusLibrary.isCorpus(try XCTUnwrap(kept)))
        // The kept copy can be linked again, and removed for good.
        let again = try CorpusLibrary.link(indexDirectory: try XCTUnwrap(kept), taken: [])
        XCTAssertEqual(again.name, "mine")
        try box.fakeIndex(named: "mine2", in: box.corpora)
        let entry = try XCTUnwrap(CorpusLibrary.entries().first { $0.name == "mine2" })
        XCTAssertNil(try CorpusLibrary.remove(entry, deleteData: true))
        XCTAssertFalse(CorpusLibrary.names().contains("mine2"))
    }

    func testAKeptCorpusWithTheSameNameGetsANumber() throws {
        let box = try TestPando.Sandbox()
        for _ in 0..<2 {
            try box.fakeIndex(named: "dup", in: box.corpora)
            try CorpusLibrary.remove(try XCTUnwrap(CorpusLibrary.entries().first), deleteData: false)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: CorpusLibrary.removedDirectory.path).sorted()
        XCTAssertEqual(kept, ["dup", "dup 2"])
    }

    func testUniqueName() {
        XCTAssertEqual(CorpusLibrary.uniqueName("UD", taken: []), "UD")
        XCTAssertEqual(CorpusLibrary.uniqueName("UD", taken: ["UD"]), "UD 2")
        XCTAssertEqual(CorpusLibrary.uniqueName("UD", taken: ["UD", "UD 2"]), "UD 3")
    }

    func testTokenCountOfAnUnreadableIndexIsNil() throws {
        let box = try TestPando.Sandbox()
        let folder = box.corpora.appendingPathComponent("odd")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "nothing useful\n".write(to: folder.appendingPathComponent("corpus.info"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, nil)
        XCTAssertEqual(CorpusLibrary.names(), ["odd"])
    }
}
