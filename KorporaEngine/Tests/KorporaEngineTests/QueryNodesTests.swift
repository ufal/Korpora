import Foundation
import XCTest
@testable import KorporaEngine

final class QueryNodesTests: XCTestCase {
    private func names(_ query: String) -> [String] { QueryNodes(query).nodes.map(\.name) }

    func testUnnamedTokensGetLettersInQueryOrder() {
        XCTAssertEqual(names(#"[lemma="give"] [upos="NOUN"] []"#), ["a", "b", "c"])
        XCTAssertEqual(QueryNodes(#"[lemma="give"] []"#).nodes.map(\.index), [0, 1])
    }

    func testTheUsersNamesAreKeptAndGeneratedOnesAvoidThem() {
        let q = QueryNodes(#"a:[upos="VERB"] [] verb:[lemma="x"]"#)
        XCTAssertEqual(q.nodes.map(\.name), ["a", "b", "verb"])
        XCTAssertEqual(q.nodes.map(\.userName), ["a", nil, "verb"])
    }

    func testGeneratedNamesSkipWhatPandoReadsElse() {
        // s, p, t, text, doc, match and matchend would be read as regions or the hit.
        let q = QueryNodes("[] [] [] [] [] [] [] [] [] [] [] [] [] [] [] [] [] [] [] []")
        XCTAssertFalse(q.nodes.map(\.name).contains("s"))
        XCTAssertFalse(q.nodes.map(\.name).contains("p"))
        XCTAssertFalse(q.nodes.map(\.name).contains("t"))
        XCTAssertEqual(Set(q.nodes.map(\.name)).count, 20)
    }

    func testTextWithNamesInsertsOnlyMissingNames() {
        let q = QueryNodes(#"[lemma="give"] > b:[deprel="obj"]"#)
        XCTAssertEqual(q.textWithNames(), #"a:[lemma="give"] > b:[deprel="obj"]"#)
        XCTAssertEqual(QueryNodes("a:[] b:[]").textWithNames(), "a:[] b:[]")
    }

    func testBracketsInQuotedAndRegexValuesAreNotTokens() {
        let q = QueryNodes(#"[form="[x]"] [form=/a\/[b]/] [lemma="a\"]"]"#)
        XCTAssertEqual(q.nodes.count, 3)
        XCTAssertEqual(q.textWithNames(), #"a:[form="[x]"] b:[form=/a\/[b]/] c:[lemma="a\"]"]"#)
    }

    func testNestedConditionsAreOneToken() {
        let q = QueryNodes(#"[upos="VERB" & child [deprel="obj"]] > []"#)
        XCTAssertEqual(q.nodes.count, 2)
        let range = q.nodes[0].bracketRange
        XCTAssertEqual((q.text as NSString).substring(with: range), #"[upos="VERB" & child [deprel="obj"]]"#)
    }

    func testDependencyArrowsAndRegionsAreNotNodes() {
        XCTAssertEqual(QueryNodes("[] > []").nodes.count, 2)
        XCTAssertEqual(QueryNodes("[] < []").nodes.count, 2)
        XCTAssertEqual(QueryNodes("<s> [] </s>").nodes.count, 1)
        XCTAssertEqual(QueryNodes(#"<text genre="Book"> [] []"#).nodes.count, 2)
        XCTAssertEqual(QueryNodes("[] <b:[]").nodes.map(\.userName), [nil, "b"])
    }

    func testConditionsAfterDoubleColonAndLaterStatementsEndTheScan() {
        let q = QueryNodes(#"a:[] b:[] :: a.form = b.form"#)
        XCTAssertEqual(q.nodes.map(\.name), ["a", "b"])
        XCTAssertEqual(QueryNodes("[] ; freq by lemma").nodes.count, 1)
    }

    func testNameIsNotTakenFromTheDoubleColon() {
        let q = QueryNodes("[] :: x.form = \"a\"")
        XCTAssertEqual(q.nodes.map(\.userName), [nil])
    }

    func testRepeatMarksMakeANodeUnpickable() {
        let q = QueryNodes(#"[upos="ADJ"]{1,2} [upos="NOUN"]? [] [upos="X"]* [upos="Y"]+ [] "#)
        XCTAssertEqual(q.nodes.map(\.repeatMark), ["{1,2}", "?", nil, "*", "+", nil])
        XCTAssertEqual(q.nodes.map(\.isPickable), [false, false, true, false, false, true])
    }

    func testRangesAreInUTF16UnitsAndCoverTheName() {
        let query = #"[form="ž"] verb:[lemma="x"]"#
        let q = QueryNodes(query)
        XCTAssertEqual((query as NSString).substring(with: q.nodes[1].range), #"verb:[lemma="x"]"#)
        XCTAssertEqual((query as NSString).substring(with: q.nodes[1].bracketRange), #"[lemma="x"]"#)
        XCTAssertEqual(QueryNodes("😀 [] []").nodes.count, 2)
    }

    func testDialectQueriesAreNotScanned() {
        let q = QueryNodes(#"MANATEE [word="a"] [word="b"]"#)
        XCTAssertTrue(q.nodes.isEmpty)
        XCTAssertNotNil(q.unsupportedReason)
    }

    func testEmptyAndTokenlessQueries() {
        XCTAssertTrue(QueryNodes("").nodes.isEmpty)
        XCTAssertTrue(QueryNodes("<s>").nodes.isEmpty)
        XCTAssertEqual(QueryNodes("").textWithNames(), "")
    }
}
