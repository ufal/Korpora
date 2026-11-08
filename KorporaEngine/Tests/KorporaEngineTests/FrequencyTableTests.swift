import Foundation
import XCTest
@testable import KorporaEngine

final class FrequencyTableTests: XCTestCase {
    private func field(_ node: String?, _ attribute: String, ignoreCase: Bool = false) -> FrequencyField {
        FrequencyField(node: node, attribute: attribute, ignoreCase: ignoreCase)
    }

    func testProgramNamesTheTokensAndListsTheFields() throws {
        let q = QueryNodes(#"[lemma="give"] > [deprel="obj"]"#)
        XCTAssertEqual(try q.frequencyProgram(for: [field("a", "lemma"), field("b", "upos")]),
                       #"a:[lemma="give"] > b:[deprel="obj"]; freq by a.lemma, b.upos"#)
    }

    func testProgramKeepsTheUsersNamesAndWritesPropertiesWithoutANode() throws {
        let q = QueryNodes(#"verb:[upos="VERB"] []"#)
        XCTAssertEqual(try q.frequencyProgram(for: [field("verb", "lemma"), field(nil, "doc.genre")]),
                       #"verb:[upos="VERB"] a:[]; freq by verb.lemma, doc_genre"#)
    }

    func testAPropertyAloneLeavesTheQueryAsTheUserWroteIt() throws {
        let q = QueryNodes(#"[lemma="cat"]"#)
        XCTAssertEqual(try q.frequencyProgram(for: [field(nil, "doc.genre")]), #"[lemma="cat"]; freq by doc_genre"#)
    }

    func testProgramRefusesUnknownRepeatedAndNoNodes() {
        let q = QueryNodes(#"[upos="ADJ"]* [upos="NOUN"]"#)
        XCTAssertThrowsError(try q.frequencyProgram(for: [])) { XCTAssertEqual($0 as? QueryNodeError, .noFields) }
        XCTAssertThrowsError(try q.frequencyProgram(for: [field("z", "lemma")])) {
            XCTAssertEqual($0 as? QueryNodeError, .unknownNode("z"))
        }
        XCTAssertThrowsError(try q.frequencyProgram(for: [field("a", "lemma")])) {
            XCTAssertEqual($0 as? QueryNodeError, .notPickable("a"))
        }
        XCTAssertNoThrow(try q.frequencyProgram(for: [field("b", "lemma")]))
    }

    func testDialectQueriesRefuseNodes() {
        let q = QueryNodes(#"MANATEE [word="a"]"#)
        XCTAssertThrowsError(try q.frequencyProgram(for: [field("a", "lemma")]))
    }

    func testFoldingMergesRowsThatDifferOnlyInCase() {
        let table = FrequencyTable(
            fields: [field("a", "form", ignoreCase: true), field("b", "upos")],
            rows: [FrequencyRow(values: ["The", "DET"], count: 5, percent: 50, perMillion: 5),
                   FrequencyRow(values: ["a", "DET"], count: 3, percent: 30, perMillion: 3),
                   FrequencyRow(values: ["the", "DET"], count: 2, percent: 20, perMillion: 2),
                   FrequencyRow(values: ["the", "PRON"], count: 1, percent: 10, perMillion: 1)],
            totalMatches: 10)
        let folded = table.folded()
        XCTAssertEqual(folded.rows.map(\.values), [["the", "DET"], ["a", "DET"], ["the", "PRON"]])
        XCTAssertEqual(folded.rows.map(\.count), [7, 3, 1])
        XCTAssertEqual(folded.rows[0].percent, 70, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(folded.rows[0].perMillion), 7, accuracy: 1e-9)
        XCTAssertEqual(folded.totalMatches, 10)
    }

    func testFoldingChangesNothingWhenNoFieldAsksForIt() {
        let table = FrequencyTable(fields: [field("a", "form")],
                                   rows: [FrequencyRow(values: ["The"], count: 1, percent: 50),
                                          FrequencyRow(values: ["the"], count: 1, percent: 50)], totalMatches: 2)
        XCTAssertEqual(table.folded(), table)
    }

    func testFoldingReordersByCountAndKeepsTiesInPandosOrder() {
        let table = FrequencyTable(
            fields: [field(nil, "form", ignoreCase: true)],
            rows: [FrequencyRow(values: ["b"], count: 2, percent: 0), FrequencyRow(values: ["A"], count: 2, percent: 0),
                   FrequencyRow(values: ["a"], count: 1, percent: 0), FrequencyRow(values: ["c"], count: 1, percent: 0)],
            totalMatches: 6)
        XCTAssertEqual(table.folded().rows.map(\.values.first!), ["a", "b", "c"])
        XCTAssertEqual(table.folded().rows.map(\.count), [3, 2, 1])
    }

    func testShownMatchesIsWhatTheRowsAccountFor() {
        let table = FrequencyTable(fields: [field(nil, "lemma")],
                                   rows: [FrequencyRow(values: ["x"], count: 4, percent: 40)], totalMatches: 10, isCut: true)
        XCTAssertEqual(table.shownMatches, 4)
        XCTAssertTrue(table.isCut)
    }

    // MARK: pando

    func testPandoGivesOneValuePerFieldForTwoNodes() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="VERB"] > [deprel="obj"]"#, in: corpus)
        let table = try await live.frequencyTable([field("a", "lemma"), field("b", "lemma")])
        XCTAssertEqual(table.totalMatches, 2)
        XCTAssertEqual(Set(table.rows.map(\.values)), [["eat", "fish"], ["eat", "meat"]])
        XCTAssertEqual(table.rows.map(\.count), [1, 1])
        XCTAssertFalse(table.isCut)
        XCTAssertEqual(table.shownMatches, table.totalMatches)
    }

    func testPandoNodesInTheOrderOfTheQueryNotOfTheSentence() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        // The subject stands before its verb, but is the second node.
        let live = try await engine.openConcordance(query: #"[upos="VERB"] > [deprel="nsubj"]"#, in: corpus)
        let table = try await live.frequencyTable([field("b", "lemma"), field("a", "upos")])
        XCTAssertEqual(Set(table.rows.map(\.values)), [["cat", "VERB"], ["dog", "VERB"]])
    }

    func testPandoNodeAndDocumentPropertyTogether() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Cats", conllu: TestPando.catsConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Cats")
        let live = try await engine.openConcordance(query: #"[lemma="cat"]"#, in: corpus)
        let table = try await live.frequencyTable([field("a", "lemma"), field(nil, "doc.genre")])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: table.rows.map { ($0.values, $0.count) }),
                       [["cat", "fiction"]: 3, ["cat", "news report"]: 2])
    }

    func testPandoIgnoreCaseAndMinimumFrequency() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="DET"]"#, in: corpus)
        let all = try await live.frequencyTable([field("a", "form", ignoreCase: true)])
        XCTAssertEqual(Set(all.rows.map(\.values)), [["the"], ["a"]])
        let frequent = try await live.frequencyTable([field("a", "form")], minFrequency: 2)
        XCTAssertTrue(frequent.rows.isEmpty)
    }

    func testPandoRefusesANodeTheQueryDoesNotHave() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="NOUN"]"#, in: corpus)
        do {
            _ = try await live.frequencyTable([field("b", "lemma")])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? QueryNodeError, .unknownNode("b"))
        }
    }
}
