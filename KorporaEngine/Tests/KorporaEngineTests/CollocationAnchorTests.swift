import Foundation
import XCTest
@testable import KorporaEngine

final class CollocationAnchorTests: XCTestCase {
    private func spec(anchor: String?, left: Int = -1, right: Int = 1) -> CollocationSpec {
        CollocationSpec(attribute: "lemma", leftWindow: left, rightWindow: right, minFrequency: 1, minCollocateFrequency: 1,
                        maxItems: 50, anchor: anchor)
    }

    func testProgramWithoutAnAnchorIsTheOldOne() throws {
        let q = QueryNodes(#"[lemma="give"] > [deprel="obj"]"#)
        XCTAssertEqual(try q.collocationProgram(attribute: "lemma", anchor: nil), #"[lemma="give"] > [deprel="obj"]; coll by lemma"#)
    }

    func testProgramWithAnAnchorNamesTheTokensAndSaysOn() throws {
        let q = QueryNodes(#"[lemma="give"] > b:[deprel="obj"]"#)
        XCTAssertEqual(try q.collocationProgram(attribute: "lemma", anchor: "a"), #"a:[lemma="give"] > b:[deprel="obj"]; coll on a by lemma"#)
        XCTAssertEqual(try q.collocationProgram(attribute: "form", anchor: "b"), #"a:[lemma="give"] > b:[deprel="obj"]; coll on b by form"#)
    }

    func testProgramRefusesAnUnknownOrRepeatedNodeOrADialect() {
        let q = QueryNodes(#"[upos="ADJ"]* [upos="NOUN"]"#)
        XCTAssertThrowsError(try q.collocationProgram(attribute: "lemma", anchor: "z")) { XCTAssertEqual($0 as? QueryNodeError, .unknownNode("z")) }
        XCTAssertThrowsError(try q.collocationProgram(attribute: "lemma", anchor: "a")) { XCTAssertEqual($0 as? QueryNodeError, .notPickable("a")) }
        XCTAssertThrowsError(try QueryNodes(#"MANATEE [word="a"]"#).collocationProgram(attribute: "lemma", anchor: "a"))
    }

    func testASavedSpecWithoutAnAnchorStillDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec(anchor: "a"))) as? [String: Any])
        XCTAssertEqual(object["anchor"] as? String, "a")
        object["anchor"] = nil
        let decoded = try JSONDecoder().decode(CollocationSpec.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.anchor)
        XCTAssertEqual(decoded.attribute, "lemma")
    }

    // MARK: pando

    func testAnAnchorTakesTheWindowAroundThatTokenOnly() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="VERB"] > [deprel="obj"]"#, in: corpus)
        let around = try await live.collocations(spec(anchor: "a")).map(\.word)
        // The verb's neighbours are its subjects; the object, a matched word, is not a collocate of its own hit.
        XCTAssertEqual(Set(around), ["cat", "dog"], "\(around)")
        let whole = try await live.collocations(spec(anchor: nil)).map(\.word)
        XCTAssertEqual(Set(whole), ["a", "cat", "dog"], "the whole match also takes the word after the object")
    }

    func testAnAnchorOnAnUnknownNodeIsAnError() async throws {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Tiny", conllu: TestPando.tinyConllu, in: box)
        let corpus = try await engine.openCorpus(name: "Tiny")
        let live = try await engine.openConcordance(query: #"[upos="VERB"]"#, in: corpus)
        do {
            _ = try await live.collocations(spec(anchor: "q"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? QueryNodeError, .unknownNode("q"))
        }
    }
}
