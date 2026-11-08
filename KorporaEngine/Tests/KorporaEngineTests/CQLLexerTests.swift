import Foundation
import XCTest
@testable import KorporaEngine

final class CQLLexerTests: XCTestCase {
    /// `text` as `kind:piece` strings, to read at a glance.
    private func lex(_ text: String) -> [String] {
        let ns = text as NSString
        return CQLLexer.tokens(in: text).map { token in
            let kind: String
            switch token.kind {
            case .string(let t): kind = t ? "str" : "str…"
            case .regex(let t): kind = t ? "re" : "re…"
            case .identifier: kind = "id"
            case .number: kind = "num"
            case .openBracket: kind = "["
            case .closeBracket: kind = "]"
            case .openParen: kind = "("
            case .closeParen: kind = ")"
            case .comparison: kind = "cmp"
            case .arrow: kind = "arrow"
            case .negation: kind = "not"
            case .logic: kind = "logic"
            case .colon: kind = "colon"
            case .doubleColon: kind = "::"
            case .assignment: kind = "=:"
            case .semicolon: kind = ";"
            case .regionTag(let t): kind = t ? "tag" : "tag…"
            case .repeatMark: kind = "rep"
            case .other: kind = "other"
            }
            return "\(kind):\(ns.substring(with: token.range))"
        }
    }

    func testATokenWithAConditionAndAString() {
        XCTAssertEqual(lex(#"[lemma="give"]"#), ["[:[", "id:lemma", "cmp:=", #"str:"give""#, "]:]"])
    }

    func testDottedNamesAreOneIdentifier() {
        XCTAssertEqual(lex("[doc.author = a.lemma]"), ["[:[", "id:doc.author", "cmp:=", "id:a.lemma", "]:]"])
    }

    func testTheEscapedQuoteDoesNotEndTheString() {
        XCTAssertEqual(lex(#"[w="a\"]b"]"#), ["[:[", "id:w", "cmp:=", #"str:"a\"]b""#, "]:]"])
    }

    func testARegexValueIsOneTokenAndAnEscapedSlashStaysInside() {
        XCTAssertEqual(lex(#"[form=/a\/[b]/]"#), ["[:[", "id:form", "cmp:=", #"re:/a\/[b]/"#, "]:]"])
        XCTAssertEqual(lex(#"[form!=/x/]"#), ["[:[", "id:form", "cmp:!=", "re:/x/", "]:]"])
    }

    func testASlashAnywhereElseIsNotARegex() {
        XCTAssertEqual(lex("[] / []"), ["[:[", "]:]", "other:/", "[:[", "]:]"])
    }

    func testUnterminatedStringAndRegexAreMarked() {
        XCTAssertEqual(lex(#"[w="fo"#), ["[:[", "id:w", "cmp:=", #"str…:"fo"#])
        XCTAssertEqual(lex("[w=/fo"), ["[:[", "id:w", "cmp:=", "re…:/fo"])
    }

    func testOperatorsInsideBracketsAreComparisons() {
        XCTAssertEqual(lex("[freq < 5 & x >= 2 & y != 1]"),
                       ["[:[", "id:freq", "cmp:<", "num:5", "logic:&", "id:x", "cmp:>=", "num:2", "logic:&", "id:y", "cmp:!=", "num:1", "]:]"])
    }

    func testBetweenTokensTheyAreDependencyArrows() {
        XCTAssertEqual(lex("[] > [] < [] >> [] << [] !> [] !< []").filter { $0.hasPrefix("arrow") },
                       ["arrow:>", "arrow:<", "arrow:>>", "arrow:<<", "arrow:!>", "arrow:!<"])
    }

    func testNegationAndLogicInsideATokenAreSeparate() {
        XCTAssertEqual(lex(#"[!(upos="X") | not child []]"#).prefix(5).map { $0 }, ["[:[", "not:!", "(:(", "id:upos", "cmp:="])
    }

    func testNodeNamesAndTheDoubleColon() {
        XCTAssertEqual(lex("a:[] b:[] :: a.form = b.form"),
                       ["id:a", "colon::", "[:[", "]:]", "id:b", "colon::", "[:[", "]:]", ":::::", "id:a.form", "cmp:=", "id:b.form"])
    }

    func testAnAssignmentNamesAQuery() {
        XCTAssertEqual(lex("Books =: []").prefix(2).map { $0 }, ["id:Books", "=::=:"])
    }

    func testRepeatMarksFollowATokenDirectly() {
        XCTAssertEqual(lex("[]* []+ []? []{1,2} []{2}").filter { $0.hasPrefix("rep") }, ["rep:*", "rep:+", "rep:?", "rep:{1,2}", "rep:{2}"])
        XCTAssertEqual(lex("[] *").last, "other:*", "not attached to a token")
    }

    func testRegionTagsAreOneTokenWhateverTheyHold() {
        XCTAssertEqual(lex(#"<text genre="a > b"> [] </text>"#), [#"tag:<text genre="a > b">"#, "[:[", "]:]", "tag:</text>"])
        XCTAssertEqual(lex("<s/>"), ["tag:<s/>"])
    }

    func testAClosingTagAfterATokenIsStillATag() {
        XCTAssertEqual(lex("<s> [] </s>").last, "tag:</s>")
    }

    func testAnArrowFollowedByANamedTokenIsNotATag() {
        XCTAssertEqual(lex("[] <b:[]"), ["[:[", "]:]", "arrow:<", "id:b", "colon::", "[:[", "]:]"])
        XCTAssertEqual(lex("[] < b:[]").dropFirst(2).first, "arrow:<")
    }

    func testATagAfterAScopingWordIsATagAndAfterATokenAnArrow() {
        XCTAssertEqual(lex("[] within <s>").last, "tag:<s>")
        XCTAssertEqual(lex("[] <").last, "arrow:<")
        XCTAssertEqual(lex("<").last, "tag…:<")
        XCTAssertEqual(lex("<tex").last, "tag…:<tex")
        XCTAssertEqual(lex(#"<text gen="x" "#).last, #"tag…:<text gen="x" "#)
    }

    func testTheKindIsDecidedBeforeTheTextEndsToo() {
        XCTAssertTrue(CQLLexer.tokens(in: "<tex").last!.isUnterminated)
        XCTAssertFalse(CQLLexer.tokens(in: "<tex>").last!.isUnterminated)
        XCTAssertTrue(CQLLexer.tokens(in: #"[w="x"#).last!.isUnterminated)
    }

    func testSemicolonsSeparateStatements() {
        XCTAssertEqual(lex("[] ; freq by lemma"), ["[:[", "]:]", ";:;", "id:freq", "id:by", "id:lemma"])
    }

    func testDepthIsTheBracketsAroundAToken() {
        let depths = CQLLexer.tokens(in: #"[upos="NOUN" & child [x="y"]] []"#).map(\.depth)
        // [ upos = "NOUN" & child [ x = "y" ] ] [ ]
        XCTAssertEqual(depths, [0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 0, 0, 0])
        XCTAssertEqual(CQLLexer.openDepth(after: CQLLexer.tokens(in: "[a [b")), 2)
        XCTAssertEqual(CQLLexer.openDepth(after: CQLLexer.tokens(in: "[a] ]")), 0)
    }

    func testWhatEndsAnOperand() {
        func ends(_ text: String) -> Bool { CQLLexer.endsOperand(CQLLexer.tokens(in: text).last, text: text) }
        for text in ["[]", #"[w="x"]"#, "[a=5", "[a=b", "[a", "[a=/x/", "[]*", "[a !", "[] >", "(a)"] { XCTAssertTrue(ends(text), text) }
        for text in ["", "[", "<s>", "within", "not", "a:", "[] ::", "[] ;", "[a &", "=:"] { XCTAssertFalse(ends(text), text) }
    }

    func testEmojiAndOtherUnitsDoNotBreakTheRanges() {
        let tokens = CQLLexer.tokens(in: "😀 [lemma=\"ž\"]")
        let ns = "😀 [lemma=\"ž\"]" as NSString
        XCTAssertEqual(ns.substring(with: tokens.first(where: { $0.kind == .openBracket })!.range), "[")
        XCTAssertEqual(ns.substring(with: tokens.last!.range), "]")
    }

    func testEmptyAndBlankTextsHaveNoTokens() {
        XCTAssertTrue(CQLLexer.tokens(in: "").isEmpty)
        XCTAssertTrue(CQLLexer.tokens(in: " \t\n ").isEmpty)
    }

    func testEveryCharacterIsCoveredBySomeTokenOrWhitespace() {
        let text = #"Books =: a:[lemma="x" & !(upos=/N.*/)]{1,2} > b:[] within <s> :: a.form != b.form ; freq by a.lemma"#
        let ns = text as NSString
        var covered = Set<Int>()
        for token in CQLLexer.tokens(in: text) { for i in token.range.location..<token.end { covered.insert(i) } }
        for i in 0..<ns.length where ns.character(at: i) != 0x20 { XCTAssertTrue(covered.contains(i), "character \(i) of the text") }
    }
}
