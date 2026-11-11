import Foundation
import XCTest
@testable import KorporaEngine

final class KWICMatchTests: XCTestCase {
    func testAWordBetweenTheMatchedTokensIsNotPartOfTheMatch() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Cats", conllu: TestPando.catsConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Cats")
        // "the big cat sleeps": the noun and its determiner match, the adjective between them doesn't.
        let live = try await engine.openConcordance(query: #"[upos="NOUN"] > [deprel="det"]"#, in: corpus)
        let line = try await live.kwicLines(range: 0..<1, leftContext: "-5", rightContext: "5", kwicAttr: "form",
                                            secondaryAttributes: [])[0]
        XCTAssertEqual(line.kwicTokens.map(\.word), ["the", "big", "cat"])
        XCTAssertEqual(line.kwicTokens.map(\.isMatch), [true, false, true])
    }

    func testAnAdjacentMatchIsMatchedWhole() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Cats", conllu: TestPando.catsConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Cats")
        let live = try await engine.openConcordance(query: #"[lemma="cat"] [lemma="sleep"]"#, in: corpus)
        let line = try await live.kwicLines(range: 0..<1, leftContext: "-5", rightContext: "5", kwicAttr: "form",
                                            secondaryAttributes: [])[0]
        XCTAssertEqual(line.kwicTokens.map(\.isMatch), [true, true])
    }
}
