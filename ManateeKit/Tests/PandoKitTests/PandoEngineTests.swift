import CorpusEngine
import Foundation
import PandoKit
import XCTest

/// pando through the engine protocols. Needs a pando build: set
/// KORPORA_PANDO_LIB to its libpando.dylib (`pando-index` is expected beside
/// it); the tests skip without one.
final class PandoEngineTests: XCTestCase {
    private static var root: URL!
    private static var library: PandoLibrary?

    /// Two sentences, with real heads: "the cat eats fish" / "a dog eats meat".
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

    override class func setUp() {
        super.setUp()
        guard let path = ProcessInfo.processInfo.environment["KORPORA_PANDO_LIB"],
              let library = try? PandoLibrary(path: path) else { return }
        let tool = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pando-index")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PandoKitTests-\(UUID().uuidString)")
        let input = root.appendingPathComponent("in")
        do {
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            try conllu.write(to: input.appendingPathComponent("t.conllu"), atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = tool
            process.arguments = [input.path, root.appendingPathComponent("tiny").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
        } catch { return }
        Self.root = root
        Self.library = library
    }

    override class func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func engine() throws -> PandoEngine {
        guard let library = Self.library, let root = Self.root else {
            throw XCTSkip("set KORPORA_PANDO_LIB to a libpando.dylib (with pando-index beside it)")
        }
        return PandoEngine(library: library, corporaRoot: root)
    }

    func testEngineIdentityAndCapabilities() throws {
        let engine = try engine()
        XCTAssertEqual(engine.id, "pando")
        XCTAssertFalse(engine.capabilities.contains(.sort))
        XCTAssertFalse(engine.capabilities.contains(.subcorpora))
    }

    func testMissingLibraryIsAClearError() {
        XCTAssertThrowsError(try PandoLibrary(path: "/nonexistent/libpando.dylib")) { error in
            XCTAssertTrue("\(error)".contains("isn\u{2019}t available"), "\(error)")
        }
    }

    func testOpenAndSchema() async throws {
        let corpus = try await engine().openCorpus(name: "tiny")
        let size = try await corpus.size
        XCTAssertEqual(size, 8)
        let info = try await corpus.info()
        XCTAssertTrue(info.attributes.contains("lemma") && info.attributes.contains("upos"))
        XCTAssertTrue(info.structures.contains { $0.name == "s" })
    }

    func testOpeningAMissingCorpusSaysWhy() async throws {
        let engine = try engine()
        do {
            _ = try await engine.openCorpus(name: "nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("nope") || "\(error)".contains("Cannot open"), "\(error)")
        }
    }

    func testQueryKwicThroughTheProtocol() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: "tiny")
        let live = try await engine.openConcordance(query: #"[lemma="eat"]"#, in: corpus)
        let size = await live.size
        XCTAssertEqual(size, 2)
        let lines = try await live.kwicLines(leftContext: "-3", rightContext: "3", kwicAttr: "word",
                                              secondaryAttributes: ["lemma", "upos"])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.kwic), ["eats", "eats"])
        XCTAssertEqual(lines.map(\.position), [2, 6])
        XCTAssertEqual(lines[0].kwicTokens.first?.secondaryAttributes["lemma"], "eat")
        XCTAssertEqual(lines[0].kwicTokens.first?.secondaryAttributes["upos"], "VERB")
        XCTAssertEqual(lines[0].left, "the cat")
        // A token window, not a sentence: it runs on into the next sentence, as in Manatee.
        XCTAssertEqual(lines[0].right, "fish a dog")
    }

    func testDependencyQueryWorks() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: "tiny")
        let live = try await engine.openConcordance(query: #"[upos="NOUN" & deprel="obj"]"#, in: corpus)
        let lines = try await live.kwicLines()
        XCTAssertEqual(lines.map(\.kwic).sorted(), ["fish", "meat"])
    }

    func testFrequencyAndCollocations() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: "tiny")
        let live = try await engine.openConcordance(query: #"[upos="NOUN"]"#, in: corpus)
        let items = try await live.frequencyDistribution([FrequencyCriterion(attribute: "word")])
        XCTAssertEqual(Set(items.map(\.word)), ["cat", "fish", "dog", "meat"])
        XCTAssertEqual(items.map(\.freq).reduce(0, +), 4)
        let collocates = try await live.collocations(
            CollocationSpec(attribute: "lemma", leftWindow: -2, rightWindow: 2, minFrequency: 1, minCollocateFrequency: 1))
        XCTAssertTrue(collocates.contains { $0.word == "eat" }, "\(collocates.map(\.word))")
    }

    func testAttributeValues() async throws {
        let corpus = try await engine().openCorpus(name: "tiny")
        let top = try await corpus.topAttributeValues(attribute: "upos", limit: 2)
        XCTAssertEqual(top.first?.value, "NOUN")
        XCTAssertEqual(top.first?.frequency, 4)
        let count = try await corpus.attributeValueCount(attribute: "upos")
        XCTAssertEqual(count, 3)
        let matching = try await corpus.attributeValues(attribute: "lemma", matching: "e.*")
        XCTAssertEqual(matching, ["eat"])
    }

    func testUnsupportedOperationsSayWhatIsMissing() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: "tiny")
        let live = try await engine.openConcordance(query: "[]", in: corpus)
        do {
            try await live.sort(SortCriteria(SortLevel(attribute: "word", anchor: .kwic)))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("Sorting"), "\(error)")
        }
        do {
            _ = try await corpus.createSubcorpus(named: "x", structure: "doc", query: "")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("Subcorpora"), "\(error)")
        }
    }

    func testACancelledTaskThrowsCancellation() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: "tiny")
        let task = Task { () -> Bool in
            do {
                _ = try await engine.openConcordance(query: #"[lemma="eat"]"#, in: corpus)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        // Cancelled before or during the query: either way it must not return a concordance.
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }

    func testBadQuerySurfacesPandosMessage() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: "tiny")
        do {
            _ = try await engine.openConcordance(query: "[lemma=", in: corpus)
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    func testAManateeHandleIsRejected() async throws {
        let engine = try engine()
        actor Other: CorpusHandle {
            nonisolated let name = "x"
            var size: Int { get async throws { 0 } }
            func info() async throws -> CorpusInfo { CorpusInfo(name: "x", sizeTokens: 0, attributes: [], structures: []) }
            func createSubcorpus(named: String, structure: String, query: String) async throws -> String { "" }
            func structuralAttributeValue(at position: Int, attribute: String) async throws -> String { "" }
            func positionalAttributeRange(from: Int, to: Int, attribute: String) async throws -> String { "" }
            func attributeValueCount(attribute: String) async throws -> Int { 0 }
            func attributeValues(attribute: String) async throws -> [String] { [] }
            func attributeValues(attribute: String, matching: String, ignoreCase: Bool, limit: Int) async throws -> [String] { [] }
            func topAttributeValues(attribute: String, limit: Int) async throws -> [(value: String, frequency: Int)] { [] }
            func topAttributeValues(attribute: String, matching: String, ignoreCase: Bool, limit: Int)
                async throws -> [(value: String, frequency: Int)] { [] }
            func openSubcorpusHandle(atPath path: String) async throws -> any CorpusHandle { self }
        }
        do {
            _ = try await engine.openConcordance(query: "[]", in: Other())
            XCTFail("expected an error")
        } catch let error as CorpusEngineError {
            XCTAssertTrue("\(error)".contains("pando"))
        }
    }
}
