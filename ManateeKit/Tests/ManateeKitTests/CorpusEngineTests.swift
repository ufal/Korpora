import CorpusEngine
import ManateeKit
import XCTest

/// Everything through the engine-neutral protocols only: what the app sees
/// after Phase B (docs/pando-analysis.md).
final class CorpusEngineTests: XCTestCase {
    private static var fixture: TestCorpusFixture!
    private let engine: any CorpusEngine = ManateeEngine()

    override class func setUp() {
        super.setUp()
        do {
            fixture = try TestCorpusFixture.build(corpusName: "mkiengine")
        } catch {
            XCTFail("failed to build test corpus fixture: \(error)")
        }
    }

    override class func tearDown() {
        fixture?.cleanUp()
        fixture = nil
        super.tearDown()
    }

    func testEngineHasAStableId() {
        XCTAssertEqual(engine.id, "manatee")
    }

    func testOpenCorpusAndReadItsSchema() async throws {
        let corpus = try await engine.openCorpus(name: Self.fixture.corpusName)
        XCTAssertEqual(corpus.name, Self.fixture.corpusName)
        let size = try await corpus.size
        XCTAssertEqual(size, 17)
        let info = try await corpus.info()
        XCTAssertTrue(info.attributes.contains("word"))
        XCTAssertEqual(info.sizeTokens, 17)
    }

    func testOpenMissingCorpusThrows() async {
        do {
            _ = try await engine.openCorpus(name: "no-such-corpus-\(UUID().uuidString)")
            XCTFail("expected an error")
        } catch {}
    }

    func testRunAQueryAndOperateOnItThroughTheProtocol() async throws {
        let corpus = try await engine.openCorpus(name: Self.fixture.corpusName)
        let live = try await engine.openConcordance(query: #"[tag="NN"]"#, in: corpus)
        let count = await live.size
        XCTAssertEqual(count, 4)

        let lines = try await live.kwicLines()
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.map(\.position), [3, 7, 11, 15])

        try await live.sample(lines: 2)
        let sampled = await live.size
        XCTAssertEqual(sampled, 2)

        let histogram = try await live.hitHistogram(bins: 2, corpusSize: 17)
        XCTAssertEqual(histogram.reduce(0, +), 2)
    }

    func testAnalysisThroughTheProtocol() async throws {
        let corpus = try await engine.openCorpus(name: Self.fixture.corpusName)
        let live = try await engine.openConcordance(query: #"[tag="NN"]"#, in: corpus)
        let items = try await live.frequencyDistribution([FrequencyCriterion(attribute: "word")])
        XCTAssertEqual(items.map(\.freq).reduce(0, +), 4)
        try await live.sort(SortCriteria(SortLevel(attribute: "word", anchor: .kwic)))
    }

    func testSubcorpusThroughTheProtocol() async throws {
        let corpus = try await engine.openCorpus(name: Self.fixture.corpusName)
        let path = try await corpus.createSubcorpus(
            named: "engine-seam", structure: "doc", query: #"id="1""#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sub = try await corpus.openSubcorpusHandle(atPath: path)
        let size = try await sub.size
        XCTAssertEqual(size, 9)  // document 1 only
    }

    func testAForeignCorpusHandleIsRejected() async throws {
        actor Foreign: CorpusHandle {
            nonisolated let name = "foreign"
            var size: Int { get async throws { 0 } }
            func info() async throws -> CorpusInfo { CorpusInfo(name: "f", sizeTokens: 0, attributes: [], structures: []) }
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
            _ = try await engine.openConcordance(query: "[]", in: Foreign())
            XCTFail("expected an error")
        } catch let error as CorpusEngineError {
            XCTAssertTrue("\(error)".contains("manatee"))
        }
    }
}
