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

    // MARK: Naming and renaming

    func testAGenericIndexFolderIsNamedAfterTheFolderThatHoldsIt() {
        func suggestion(_ path: String) -> String { CorpusLibrary.suggestedName(forIndex: URL(fileURLWithPath: path)) }
        XCTAssertEqual(suggestion("/data/syn2025/idx"), "syn2025")
        XCTAssertEqual(suggestion("/data/syn2025/IDX"), "syn2025")
        XCTAssertEqual(suggestion("/home/ud/pando_idx"), "ud")
        XCTAssertEqual(suggestion("/data/Czech National Corpus"), "Czech National Corpus", "a meaningful name is kept")
        XCTAssertEqual(suggestion("/idx"), "idx", "nothing better to use")
    }

    func testLinkingUnderAChosenName() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "idx", in: box.elsewhere.appendingPathComponent("syn2025"), tokens: 9)
        let entry = try CorpusLibrary.link(indexDirectory: target, name: "  SYN2025  ", taken: [])
        XCTAssertEqual(entry.name, "SYN2025", "trimmed")
        XCTAssertEqual(CorpusLibrary.names(), ["SYN2025"])
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, 9)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "the folder is not renamed")
        // Without a name it uses the suggestion.
        let second = try box.fakeIndex(named: "idx", in: box.elsewhere.appendingPathComponent("ud"))
        XCTAssertEqual(try CorpusLibrary.link(indexDirectory: second, taken: []).name, "ud")
    }

    func testLinkingRefusesBadOrTakenNames() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "idx", in: box.elsewhere)
        for bad in ["", "   ", "a/b", "a:b", ".hidden"] {
            XCTAssertThrowsError(try CorpusLibrary.link(indexDirectory: target, name: bad, taken: []), bad) {
                guard case .invalidName = $0 as? CorpusLibrary.LibraryError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try CorpusLibrary.link(indexDirectory: target, name: "Taken", taken: ["Taken"])) {
            XCTAssertEqual($0 as? CorpusLibrary.LibraryError, .nameTaken("Taken"))
        }
        XCTAssertTrue(CorpusLibrary.names().isEmpty, "nothing was linked")
    }

    func testRenamingABuiltCorpusRenamesItsFolder() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "idx", in: box.corpora, tokens: 77)
        let entry = try XCTUnwrap(CorpusLibrary.entries().first)
        let renamed = try CorpusLibrary.rename(entry, to: " Syn2025 ", taken: ["idx"])
        XCTAssertEqual(renamed.name, "Syn2025")
        XCTAssertEqual(CorpusLibrary.names(), ["Syn2025"])
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, 77)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.directory.path))
        XCTAssertEqual(CorpusLibrary.directory(forName: "Syn2025")?.lastPathComponent, "Syn2025")
    }

    func testRenamingALinkedCorpusRenamesOnlyTheLink() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "idx", in: box.elsewhere.appendingPathComponent("syn2025"), tokens: 5)
        let entry = try CorpusLibrary.link(indexDirectory: target, name: "idx", taken: [])
        let renamed = try CorpusLibrary.rename(entry, to: "Syn2025", taken: ["idx"])
        XCTAssertEqual(CorpusLibrary.names(), ["Syn2025"])
        XCTAssertEqual(renamed.origin, .linked(target: target.resolvingSymlinksInPath()))
        XCTAssertTrue(CorpusLibrary.isCorpus(target), "the real folder keeps its name and content")
        XCTAssertEqual(target.lastPathComponent, "idx")
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, 5, "still readable through the new link")
    }

    func testRenamingRefusesClashesAndBadNamesAndChangesNothing() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "one", in: box.corpora)
        try box.fakeIndex(named: "two", in: box.corpora)
        let one = try XCTUnwrap(CorpusLibrary.entries().first { $0.name == "one" })
        XCTAssertThrowsError(try CorpusLibrary.rename(one, to: "two", taken: ["one", "two"])) {
            XCTAssertEqual($0 as? CorpusLibrary.LibraryError, .nameTaken("two"))
        }
        for bad in ["", "x/y", ".dot"] {
            XCTAssertThrowsError(try CorpusLibrary.rename(one, to: bad, taken: ["one", "two"]), bad)
        }
        XCTAssertEqual(CorpusLibrary.names(), ["one", "two"])
        // The same name (or the same after trimming) is not an error and does nothing.
        XCTAssertEqual(try CorpusLibrary.rename(one, to: " one ", taken: ["one", "two"]).name, "one")
    }

    func testChangingOnlyTheCapitalsWorksOnACaseInsensitiveDisk() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "syn", in: box.corpora, tokens: 3)
        let entry = try XCTUnwrap(CorpusLibrary.entries().first)
        let renamed = try CorpusLibrary.rename(entry, to: "SYN", taken: ["syn"])
        XCTAssertEqual(renamed.name, "SYN")
        let listed = try FileManager.default.contentsOfDirectory(atPath: box.corpora.path)
        XCTAssertEqual(listed, ["SYN"], "the folder really has the new spelling")
        XCTAssertEqual(CorpusLibrary.entries().first?.tokens, 3)
    }

    func testRenamingMovesTheSavedSubcorporaAlong() throws {
        let box = try TestPando.Sandbox()
        try SubcorpusLibrary.save(Subcorpus(name: "Fiction", restriction: SubcorpusRestriction()), in: "idx")
        SubcorpusLibrary.rename(corpus: "idx", to: "Syn2025")
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "Syn2025").map(\.name), ["Fiction"])
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "idx"), [])
        _ = box
    }

    // MARK: Missing, relinking, bringing in

    func testALinkWhoseFolderMovedIsListedAsMissingOnlyWhenAsked() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "far", in: box.elsewhere, tokens: 7)
        try CorpusLibrary.link(indexDirectory: target, taken: [])
        try FileManager.default.moveItem(at: target, to: box.elsewhere.appendingPathComponent("moved"))

        XCTAssertTrue(CorpusLibrary.entries().isEmpty, "not searchable")
        let all = CorpusLibrary.entries(includingMissing: true)
        XCTAssertEqual(all.map(\.name), ["far"])
        XCTAssertTrue(all[0].isMissing)
        XCTAssertNil(all[0].tokens)
        if case .linked(let leads) = all[0].origin {
            XCTAssertEqual(leads.path, target.resolvingSymlinksInPath().path, "where the link used to lead")
        } else {
            XCTFail("a link")
        }
        XCTAssertEqual(CorpusLibrary.names(includingMissing: true), ["far"])
        XCTAssertTrue(CorpusLibrary.names().isEmpty)
    }

    func testRelinkingPointsTheSameNameAtTheMovedFolder() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "far", in: box.elsewhere, tokens: 7)
        try CorpusLibrary.link(indexDirectory: target, taken: [])
        let moved = box.elsewhere.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: target, to: moved)
        let broken = try XCTUnwrap(CorpusLibrary.entries(includingMissing: true).first)

        let fixed = try CorpusLibrary.relink(broken, to: moved)
        XCTAssertEqual(fixed.name, "far")
        XCTAssertFalse(fixed.isMissing)
        XCTAssertEqual(fixed.tokens, 7)
        let entries = CorpusLibrary.entries(includingMissing: true)
        XCTAssertEqual(entries.map(\.name), ["far"])
        XCTAssertFalse(entries[0].isMissing)
    }

    func testRelinkingToSomethingThatIsNotAnIndexChangesNothing() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "far", in: box.elsewhere)
        let entry = try CorpusLibrary.link(indexDirectory: target, taken: [])
        let empty = box.elsewhere.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CorpusLibrary.relink(entry, to: empty))
        XCTAssertEqual(CorpusLibrary.entries().first?.origin, .linked(target: target.resolvingSymlinksInPath()))
    }

    func testBuiltCorporaCannotBeRelinked() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "mine", in: box.corpora)
        let entry = try XCTUnwrap(CorpusLibrary.entries().first)
        XCTAssertThrowsError(try CorpusLibrary.relink(entry, to: box.corpora.appendingPathComponent("mine")))
    }

    func testBringingInACopyLeavesTheOriginalAndMakesTheCorpusBuilt() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "far", in: box.elsewhere, tokens: 9)
        let entry = try CorpusLibrary.link(indexDirectory: target, taken: [])

        let built = try CorpusLibrary.bringIn(entry, copy: true)
        XCTAssertEqual(built.origin, .built)
        XCTAssertEqual(built.tokens, 9)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("corpus.info").path), "original stays")
        XCTAssertEqual(CorpusLibrary.entries().map(\.isLinked), [false])
        XCTAssertEqual(CorpusLibrary.entries(includingMissing: true).count, 1, "the link is gone")
        XCTAssertEqual(CorpusLibrary.directory(forName: "far")?.deletingLastPathComponent().lastPathComponent, "Corpora")
    }

    func testBringingInByMovingTakesTheFolderAway() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "far", in: box.elsewhere, tokens: 9)
        let entry = try CorpusLibrary.link(indexDirectory: target, taken: [])
        try CorpusLibrary.bringIn(entry, copy: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "moved out")
        XCTAssertEqual(CorpusLibrary.entries().map(\.tokens), [9])
    }

    func testBringingInRefusesAMissingFolderAndATakenName() throws {
        let box = try TestPando.Sandbox()
        let target = try box.fakeIndex(named: "far", in: box.elsewhere)
        let entry = try CorpusLibrary.link(indexDirectory: target, taken: [])
        try box.fakeIndex(named: "far", in: box.corpora)  // the same name, built
        XCTAssertThrowsError(try CorpusLibrary.bringIn(entry, copy: true)) {
            XCTAssertEqual($0 as? CorpusLibrary.LibraryError, .nameTaken("far"))
        }
        try FileManager.default.removeItem(at: target)
        var broken = entry
        broken.isMissing = true
        XCTAssertThrowsError(try CorpusLibrary.bringIn(broken, copy: true))
    }

    // MARK: The folder for built corpora

    func testAChosenFolderReplacesTheDefaultButNotTheTestOverride() throws {
        let box = try TestPando.Sandbox()
        let chosen = box.elsewhere.appendingPathComponent("My Corpora")
        CorpusLibrary.customBaseDirectory = chosen
        defer { CorpusLibrary.customBaseDirectory = nil }
        XCTAssertEqual(CorpusLibrary.baseDirectory.path, box.corpora.path, "the environment override wins (tests)")

        unsetenv("KORPORA_CORPORA_DIRECTORY")
        XCTAssertEqual(CorpusLibrary.baseDirectory.path, chosen.path)
        XCTAssertTrue(CorpusLibrary.baseDirectoryIsChosen)
        XCTAssertFalse(CorpusLibrary.baseDirectoryIsAvailable, "a disk that isn't there")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        XCTAssertTrue(CorpusLibrary.baseDirectoryIsAvailable)
        try box.fakeIndex(named: "here", in: chosen, tokens: 3)
        XCTAssertEqual(CorpusLibrary.entries().map(\.name), ["here"])

        CorpusLibrary.customBaseDirectory = nil
        XCTAssertTrue(CorpusLibrary.baseDirectory.path.hasSuffix("Korpora/Corpora"))
        XCTAssertFalse(CorpusLibrary.baseDirectoryIsChosen)
        XCTAssertTrue(CorpusLibrary.baseDirectoryIsAvailable, "the default is made when needed")
    }

    func testImportingIntoAMissingChosenFolderSaysSoInsteadOfCreatingIt() async throws {
        let box = try TestPando.Sandbox()
        unsetenv("KORPORA_CORPORA_DIRECTORY")
        CorpusLibrary.customBaseDirectory = box.elsewhere.appendingPathComponent("Disk That Is Gone")
        defer { CorpusLibrary.customBaseDirectory = nil }
        do {
            _ = try await CorpusImporter.importCorpus(
                name: "x", inputs: [box.root], tool: URL(fileURLWithPath: "/usr/bin/true"))
            XCTFail("should not import")
        } catch let error as CorpusImportError {
            guard case .folderUnavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.elsewhere.appendingPathComponent("Disk That Is Gone").path))
    }

    func testOnlyAWritableFolderOutsideTheCurrentOneIsAcceptable() throws {
        let box = try TestPando.Sandbox()
        let current = box.corpora
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let fine = box.elsewhere.appendingPathComponent("fine")
        try FileManager.default.createDirectory(at: fine, withIntermediateDirectories: true)
        XCTAssertNoThrow(try CorpusLibrary.validateNewBaseDirectory(fine, replacing: current))

        XCTAssertThrowsError(try CorpusLibrary.validateNewBaseDirectory(box.elsewhere.appendingPathComponent("nope"), replacing: current))
        let inside = current.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CorpusLibrary.validateNewBaseDirectory(inside, replacing: current))
        let file = box.elsewhere.appendingPathComponent("file.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CorpusLibrary.validateNewBaseDirectory(file, replacing: current))
    }

    func testMovingTheBuiltCorporaKeepsNamesAndSizesAndSkipsTakenNames() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "alpha", in: box.corpora, tokens: 11)
        try box.fakeIndex(named: "beta", in: box.corpora, tokens: 22)
        try FileManager.default.createDirectory(
            at: box.corpora.appendingPathComponent("Removed Corpora"), withIntermediateDirectories: true)  // not a corpus: stays
        let new = box.elsewhere.appendingPathComponent("SSD")
        try box.fakeIndex(named: "beta", in: new, tokens: 99)  // already there

        let result = CorpusLibrary.moveBuiltCorpora(from: box.corpora, to: new)
        XCTAssertEqual(result.moved, ["alpha"])
        XCTAssertEqual(result.skipped, ["beta"])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(CorpusLibrary.builtCorpora(in: new).map(\.name), ["alpha", "beta"])
        XCTAssertEqual(CorpusLibrary.builtCorpora(in: new).map(\.tokens), [11, 99], "the one already there is untouched")
        XCTAssertEqual(CorpusLibrary.builtCorpora(in: box.corpora).map(\.name), ["beta"], "the skipped one stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.corpora.appendingPathComponent("Removed Corpora").path))
        let names = try FileManager.default.contentsOfDirectory(atPath: new.path)
        XCTAssertEqual(names.sorted(), ["alpha", "beta"], "no staging folder left, visible or hidden")
    }

    // MARK: Copying with progress

    /// An index with a file big enough to be copied in several chunks.
    @discardableResult
    private func bigIndex(_ box: TestPando.Sandbox, named name: String, in parent: URL, megabytes: Int = 9) throws -> URL {
        let folder = try box.fakeIndex(named: name, in: parent, tokens: 5)
        try Data(count: megabytes << 20).write(to: folder.appendingPathComponent("big.dat"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("sub/small.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    func testCopyingATreeReportsEveryByteAndKeepsTheFiles() throws {
        let box = try TestPando.Sandbox()
        let source = try bigIndex(box, named: "src", in: box.elsewhere)
        let destination = box.elsewhere.appendingPathComponent("copy")
        var copied: Int64 = 0
        try CorpusLibrary.copyTree(from: source, to: destination) { copied += $0 }
        XCTAssertEqual(copied, CorpusLibrary.treeSize(source))
        XCTAssertEqual(copied, Int64(9 << 20) + Int64("size=5\nindexed_with=0.4.1\n".utf8.count) + 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("big.dat")).count, 9 << 20)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("sub/small.txt")), "x")
        XCTAssertTrue(CorpusLibrary.isCorpus(destination))
    }

    func testBringingInAcrossDisksShowsGrowingProgressEndingAtTheTotal() throws {
        let box = try TestPando.Sandbox()
        let target = try bigIndex(box, named: "far", in: box.elsewhere)
        let entry = try CorpusLibrary.link(indexDirectory: target, taken: [])
        CorpusLibrary.alwaysCopyFiles = true
        defer { CorpusLibrary.alwaysCopyFiles = false }
        var events: [CorpusLibrary.TransferProgress] = []
        let built = try CorpusLibrary.bringIn(entry, copy: false) { events.append($0) }
        XCTAssertEqual(built.origin, .built)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "moved: the original is gone afterwards")
        XCTAssertEqual(events.first?.bytesDone, 0)
        XCTAssertEqual(events.last?.bytesDone, events.last?.bytesTotal)
        XCTAssertEqual(events.map(\.bytesDone), events.map(\.bytesDone).sorted(), "never goes back")
        XCTAssertTrue(events.allSatisfy { $0.name == "far" })
    }

    func testCancellingStopsTheCopyAndLeavesTheOriginalAndNothingHalfDone() async throws {
        let box = try TestPando.Sandbox()
        let target = try bigIndex(box, named: "far", in: box.elsewhere)
        let entry = try CorpusLibrary.link(indexDirectory: target, taken: [])
        CorpusLibrary.alwaysCopyFiles = true
        defer { CorpusLibrary.alwaysCopyFiles = false }
        let outcome = await Task { () -> Error? in
            do {
                _ = try CorpusLibrary.bringIn(entry, copy: false) { progress in
                    if progress.bytesDone > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return nil
            } catch {
                return error
            }
        }.value
        XCTAssertTrue(outcome is CancellationError)
        XCTAssertTrue(CorpusLibrary.isCorpus(target), "the original stays")
        XCTAssertEqual(CorpusLibrary.entries().map(\.isLinked), [true], "still linked, not built")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: CorpusLibrary.baseDirectory.path)) ?? []
        XCTAssertTrue(left.isEmpty, "no partial copy left, and no Unfinished Work folder either: \(left)")
    }

    func testMovingCorporaAcrossDisksReportsOneRunningTotalAndCanBeCancelled() async throws {
        let box = try TestPando.Sandbox()
        try bigIndex(box, named: "a", in: box.corpora, megabytes: 5)
        try bigIndex(box, named: "b", in: box.corpora, megabytes: 5)
        let new = box.elsewhere.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        CorpusLibrary.alwaysCopyFiles = true
        defer { CorpusLibrary.alwaysCopyFiles = false }

        var events: [CorpusLibrary.TransferProgress] = []
        let all = CorpusLibrary.moveBuiltCorpora(from: box.corpora, to: new) { events.append($0) }
        XCTAssertEqual(all.moved, ["a", "b"])
        XCTAssertEqual(Set(events.map(\.bytesTotal)).count, 1, "one total for the whole job")
        XCTAssertEqual(events.last?.bytesDone, events.last?.bytesTotal)
        XCTAssertTrue(CorpusLibrary.builtCorpora(in: box.corpora).isEmpty)

        // Back again, cancelled once the second corpus has started: the first stays moved.
        let result = await Task { () -> CorpusLibrary.MoveResult in
            CorpusLibrary.moveBuiltCorpora(from: new, to: box.corpora) { progress in
                if progress.name == "b" {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.value
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.moved, ["a"])
        XCTAssertEqual(CorpusLibrary.builtCorpora(in: new).map(\.name), ["b"], "b stayed")
        XCTAssertEqual(CorpusLibrary.builtCorpora(in: box.corpora).map(\.name), ["a"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: box.corpora.path), ["a"], "nothing else there")
    }

    // MARK: Nothing hidden

    func testRemovedCorporaGoToAVisibleFolder() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "gone", in: box.corpora)
        let entry = try XCTUnwrap(CorpusLibrary.entries().first)
        let kept = try XCTUnwrap(try CorpusLibrary.remove(entry, deleteData: false))
        XCTAssertEqual(kept.deletingLastPathComponent().lastPathComponent, "Removed Corpora")
        XCTAssertFalse(kept.pathComponents.contains { $0.hasPrefix(".") }, "nothing hidden in the path")
        XCTAssertTrue(CorpusLibrary.names().isEmpty, "and it is not listed as a corpus")
    }

    func testHiddenFoldersFromEarlyVersionsBecomeVisibleAndNothingIsDeleted() throws {
        let box = try TestPando.Sandbox()
        let base = box.corpora
        try box.fakeIndex(named: "keep", in: base)
        try box.fakeIndex(named: "old one", in: base.appendingPathComponent(".Removed"), tokens: 1)
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".importing-ABC"), withIntermediateDirectories: true)
        try "partial".write(to: base.appendingPathComponent(".importing-ABC/data"), atomically: true, encoding: .utf8)

        let surfaced = CorpusLibrary.makeHiddenFoldersVisible(in: base)
        XCTAssertEqual(Set(surfaced), [".Removed", ".importing-ABC"])
        let top = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(top.sorted(), ["Removed Corpora", "Unfinished Work", "keep"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("Removed Corpora/old one/corpus.info").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Unfinished Work").path),
                       ["Left over importing-ABC"])
        XCTAssertEqual(CorpusLibrary.names(), ["keep"])
    }

    func testAnExistingRemovedCorporaFolderIsMergedWithTheHiddenOne() throws {
        let box = try TestPando.Sandbox()
        let base = box.corpora
        try box.fakeIndex(named: "same", in: base.appendingPathComponent("Removed Corpora"), tokens: 1)
        try box.fakeIndex(named: "same", in: base.appendingPathComponent(".Removed"), tokens: 2)
        CorpusLibrary.makeHiddenFoldersVisible(in: base)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Removed Corpora").path)
        XCTAssertEqual(names.sorted(), ["same", "same 2"], "both kept, neither overwritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(".Removed").path))
    }
}
