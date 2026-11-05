
import Foundation
@testable import KorporaEngine

import XCTest

/// Real indexes, set up by `scripts/pando-spike.sh`: pando's built-in sample
/// (`KORPORA_PANDO_SAMPLE`) and the full Universal Dependencies release
/// (`KORPORA_PANDO_UD`). Each test skips when its index isn't there.
final class PandoRealCorpusTests: XCTestCase {
    private func engine() throws -> PandoEngine {
        guard let path = TestPando.libraryPath else {
            throw XCTSkip("set KORPORA_PANDO_LIB (scripts/pando-spike.sh test does)")
        }
        return PandoEngine(library: try PandoLibrary(path: path), corporaRoot: URL(fileURLWithPath: "/"))
    }

    private func corpusPath(_ variable: String) throws -> String {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("\(variable) is not set (scripts/pando-spike.sh sample | ud)")
        }
        return path
    }

    // MARK: Built-in sample

    func testSampleCorpusSchemaAndKwic() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: try corpusPath("KORPORA_PANDO_SAMPLE"))
        let info = try await corpus.info()
        XCTAssertGreaterThan(info.sizeTokens, 100)
        XCTAssertTrue(["form", "lemma", "upos", "deprel"].allSatisfy(info.attributes.contains), "\(info.attributes)")

        let verbs = try await engine.openConcordance(query: #"[upos="VERB"]"#, in: corpus)
        let count = await verbs.size
        XCTAssertGreaterThan(count, 0)
        let lines = try await verbs.kwicLines(leftContext: "-5", rightContext: "5", kwicAttr: "word",
                                              secondaryAttributes: ["lemma"])
        XCTAssertEqual(lines.count, count)
        XCTAssertFalse(lines[0].kwic.isEmpty)
        XCTAssertNotNil(lines[0].kwicTokens.first?.secondaryAttributes["lemma"])
    }

    func testSampleCorpusDependencyQueryAndProfile() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: try corpusPath("KORPORA_PANDO_SAMPLE"))
        // The sample's first sentence: "the library sits between a bakery and a narrow park".
        let subjects = try await engine.openConcordance(query: #"[upos="NOUN" & deprel="nsubj"]"#, in: corpus)
        let forms = try await subjects.kwicLines().map(\.kwic)
        XCTAssertTrue(forms.contains("library"), "\(forms)")
        let freq = try await subjects.frequencyDistribution([FrequencyCriterion(attribute: "lemma")])
        XCTAssertTrue(freq.contains { $0.word == "library" })
    }

    // MARK: Full UD

    func testFullUDCorpusIsBigAndQueryable() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: try corpusPath("KORPORA_PANDO_UD"))
        let size = try await corpus.size
        XCTAssertGreaterThan(size, 10_000_000, "a UD release has tens of millions of tokens")

        let start = Date()
        let verbs = try await engine.openConcordance(query: #"[upos="VERB"]"#, in: corpus)
        let verbCount = await verbs.totalHits
        XCTAssertGreaterThan(verbCount, 1_000_000)
        let readable = await verbs.size
        XCTAssertEqual(readable, verbCount, "every hit can be read, millions or not")
        try await verbs.shuffle()
        let shuffled = await verbs.size
        XCTAssertEqual(shuffled, verbCount, "pando shuffles all of a big result")
        try await verbs.sort(SortCriteria(levels: [
            SortLevel(attribute: "form", anchor: .kwic), SortLevel(attribute: "form", anchor: .left)]))
        let loaded = await verbs.size
        XCTAssertEqual(loaded, ConcordanceLimit.defaultLimit, "what pando can't do works on the first hits")
        let page = try await engine.openConcordance(query: #"[lemma="house" & upos="NOUN"]"#, in: corpus)
        let lines = try await page.kwicLines()
        XCTAssertFalse(lines.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30, "queries on UD should be interactive")
    }

    func testFullUDCollocationsAndAttributeValues() async throws {
        let engine = try engine()
        let corpus = try await engine.openCorpus(name: try corpusPath("KORPORA_PANDO_UD"))
        let live = try await engine.openConcordance(query: #"[lemma="eat" & upos="VERB"]"#, in: corpus)
        let collocates = try await live.collocations(CollocationSpec(attribute: "lemma", minFrequency: 5))
        XCTAssertFalse(collocates.isEmpty)
        let top = try await corpus.topAttributeValues(attribute: "upos", limit: 5)
        XCTAssertEqual(top.count, 5)
        XCTAssertTrue(top.map(\.value).contains("NOUN"))
    }
}
