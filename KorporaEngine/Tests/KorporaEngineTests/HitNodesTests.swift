import Foundation
import XCTest
@testable import KorporaEngine

final class HitNodesTests: XCTestCase {
    func testTokensAreInQueryOrderAndPointAtTheirWords() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        // The subject stands before its verb in the sentence, and is the query's second token.
        let live = try await engine.openConcordance(query: #"[upos="VERB"] > [deprel="nsubj"]"#, in: corpus)
        let hit = try await live.hitNodes(forViewRow: 0, context: 5, attributes: ["lemma", "upos"])
        XCTAssertEqual(hit.tokens.count, 2)
        let verb = hit.tokens[0], subject = hit.tokens[1]
        XCTAssertEqual(hit.words[verb.wordIndex], "eats")
        XCTAssertEqual(verb.attributes["upos"], "VERB")
        XCTAssertEqual(verb.attributes["lemma"], "eat")
        XCTAssertTrue(["cat", "dog"].contains(hit.words[subject.wordIndex]))
        XCTAssertLessThan(subject.wordIndex, verb.wordIndex)
        XCTAssertTrue(hit.matchRange.contains(verb.wordIndex) && hit.matchRange.contains(subject.wordIndex))
    }

    func testContextWordsAroundTheHit() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Cats", conllu: TestPando.catsConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Cats")
        let live = try await engine.openConcordance(query: #"[lemma="cat"]"#, in: corpus)
        let hit = try await live.hitNodes(forViewRow: 0, context: 2, attributes: [])
        XCTAssertEqual(hit.words[hit.tokens[0].wordIndex], "cat")
        XCTAssertEqual(hit.matchRange.count, 1)
        XCTAssertEqual(Array(hit.words.prefix(3)), ["the", "big", "cat"])
        XCTAssertEqual(hit.tokens[0].wordIndex, 2)
        XCTAssertEqual(hit.words[3], "sleeps")
    }

    func testAHitThatIsNotThereIsAnError() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="VERB"]"#, in: corpus)
        do {
            _ = try await live.hitNodes(forViewRow: 99, context: 2, attributes: [])
            XCTFail("expected an error")
        } catch {}
    }
}
