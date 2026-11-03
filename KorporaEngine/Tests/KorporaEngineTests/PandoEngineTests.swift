import Foundation
import XCTest
@testable import KorporaEngine

/// pando through the engine protocols. Needs a pando build (`scripts/pando-spike.sh build`,
/// or `KORPORA_PANDO_LIB`); skips without one.
final class PandoEngineTests: XCTestCase {
    func testEngineIdentity() throws {
        let engine = PandoEngine(library: try TestPando.library())
        XCTAssertEqual(engine.id, "pando")
        XCTAssertEqual(engine.capabilities, .all)
    }

    func testMissingLibraryIsAClearError() {
        XCTAssertThrowsError(try PandoLibrary(path: "/nonexistent/libpando.dylib")) { error in
            XCTAssertTrue("\(error)".contains("isn\u{2019}t available"), "\(error)")
        }
    }

    func testOpenAndSchema() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let size = try await corpus.size
        XCTAssertEqual(size, 8)
        let info = try await corpus.info()
        XCTAssertTrue(info.attributes.contains("lemma") && info.attributes.contains("upos"))
        XCTAssertEqual(info.defaultAttribute, "form")
        XCTAssertTrue(info.structures.contains { $0.name == "s" })
    }

    func testOpeningAMissingCorpusSaysWhy() async throws {
        let engine = PandoEngine(library: try TestPando.library())
        let box = try TestPando.Sandbox()
        _ = box
        do {
            _ = try await engine.openCorpus(name: "nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("nope"), "\(error)")
        }
    }

    func testQueryKwicThroughTheProtocol() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[lemma="eat"]"#, in: corpus)
        let size = await live.size
        let total = await live.totalHits
        XCTAssertEqual(size, 2)
        XCTAssertEqual(total, 2)
        let lines = try await live.kwicLines(leftContext: "-3", rightContext: "3", kwicAttr: "form",
                                              secondaryAttributes: ["lemma", "upos"])
        XCTAssertEqual(lines.map(\.kwic), ["eats", "eats"])
        XCTAssertEqual(lines.map(\.position), [2, 6])
        XCTAssertEqual(lines[0].kwicTokens.first?.secondaryAttributes["lemma"], "eat")
        XCTAssertEqual(lines[0].kwicTokens.first?.secondaryAttributes["upos"], "VERB")
        XCTAssertEqual(lines[0].left, "the cat")
        // A token window, not a sentence: it runs on into the next sentence.
        XCTAssertEqual(lines[0].right, "fish a dog")
        // The window is applied to what was loaded.
        let narrow = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(narrow.map(\.left), ["cat", "dog"])
        XCTAssertEqual(narrow.map(\.right), ["fish", "meat"])
    }

    func testDisplayAttributeCanBeAnythingTheMatchTokensCarry() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="NOUN"]"#, in: corpus)
        let lemmas = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "lemma", secondaryAttributes: [])
        XCTAssertEqual(lemmas.map(\.kwic), ["cat", "fish", "dog", "meat"])
    }

    func testDependencyQueryWorks() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="NOUN" & deprel="obj"]"#, in: corpus)
        let lines = try await live.kwicLines()
        XCTAssertEqual(lines.map(\.kwic).sorted(), ["fish", "meat"])
    }

    func testFrequencyAndCollocations() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="NOUN"]"#, in: corpus)
        let items = try await live.frequencyDistribution([FrequencyCriterion(attribute: "form")])
        XCTAssertEqual(Set(items.map(\.word)), ["cat", "fish", "dog", "meat"])
        XCTAssertEqual(items.map(\.freq).reduce(0, +), 4)
        let collocates = try await live.collocations(
            CollocationSpec(attribute: "lemma", leftWindow: -2, rightWindow: 2, minFrequency: 1, minCollocateFrequency: 1))
        XCTAssertTrue(collocates.contains { $0.word == "eat" }, "\(collocates.map(\.word))")
    }

    func testFrequencyByARegionAttribute() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Cats", conllu: TestPando.catsConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Cats")
        let live = try await engine.openConcordance(query: #"[lemma="cat"]"#, in: corpus)
        let items = try await live.frequencyDistribution([FrequencyCriterion(attribute: "doc.genre")])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.word, $0.freq) }), ["fiction": 3, "news report": 2])
    }

    func testAttributeValues() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let top = try await corpus.topAttributeValues(attribute: "upos", limit: 2)
        XCTAssertEqual(top.first?.value, "NOUN")
        XCTAssertEqual(top.first?.frequency, 4)
        let count = try await corpus.attributeValueCount(attribute: "upos")
        XCTAssertEqual(count, 3)
        let matching = try await corpus.attributeValues(attribute: "lemma", matching: "e.*")
        XCTAssertEqual(matching, ["eat"])
    }

    func testRegionAttributeValuesWithCounts() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Cats", conllu: TestPando.catsConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Cats")
        let genres = try await corpus.topAttributeValues(attribute: "doc.genre", limit: 10)
        XCTAssertEqual(Set(genres.map(\.value)), ["fiction", "news report"])
        XCTAssertEqual(genres.map(\.frequency), [1, 1], "counts are documents, not tokens")
        let info = try await corpus.info()
        XCTAssertTrue(info.structures.first { $0.name == "doc" }?.attributes.contains("genre") == true)
    }

    func testACancelledTaskThrowsCancellation() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
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
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }

    func testBadQuerySurfacesPandosMessage() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        do {
            _ = try await engine.openConcordance(query: "[lemma=", in: corpus)
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    func testAHandleFromAnotherEngineIsRejected() async throws {
        let engine = PandoEngine(library: try TestPando.library())
        actor Other: CorpusHandle {
            nonisolated let name = "x"
            var size: Int { get async throws { 0 } }
            func info() async throws -> CorpusInfo { CorpusInfo(name: "x", sizeTokens: 0, attributes: [], structures: []) }
            func attributeValueCount(attribute: String) async throws -> Int { 0 }
            func attributeValues(attribute: String) async throws -> [String] { [] }
            func attributeValues(attribute: String, matching: String, ignoreCase: Bool, limit: Int) async throws -> [String] { [] }
            func topAttributeValues(attribute: String, limit: Int) async throws -> [(value: String, frequency: Int)] { [] }
            func topAttributeValues(attribute: String, matching: String, ignoreCase: Bool, limit: Int)
                async throws -> [(value: String, frequency: Int)] { [] }
        }
        do {
            _ = try await engine.openConcordance(query: "[]", in: Other())
            XCTFail("expected an error")
        } catch let error as CorpusEngineError {
            XCTAssertTrue("\(error)".contains("pando"))
        }
    }
}
