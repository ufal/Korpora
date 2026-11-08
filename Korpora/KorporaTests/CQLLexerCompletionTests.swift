import AppKit
import Foundation
import KorporaEngine
import Testing

@testable import Korpora

/// What the shared lexer made possible: completion after `::`, in region tags and not inside regexes, a `<` that
/// pairs after a region tag, and colours read from tokens.
@MainActor
struct CQLLexerCompletionTests {
    private func context(_ text: String) -> CQLCompletionContext {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return CQLCompletionContext.at(text: text, partialWordRange: textView.rangeForUserCompletion)
    }

    private let info = CorpusInfo(
        name: "c", sizeTokens: 10, attributes: ["form", "lemma", "upos"],
        structures: [StructureInfo(name: "text", attributes: ["genre", "title"]), StructureInfo(name: "s", attributes: ["sent_id"])])

    // MARK: Contexts

    @Test func afterANameAndADotInAConditionTheTokensAttributesAreOffered() {
        #expect(context("a:[] b:[] :: a.le") == .nodeAttribute(node: "a", prefix: "le"))
        #expect(context("a:[] :: a.") == .nodeAttribute(node: "a", prefix: ""))
        #expect(context("a:[] :: match.") == .nodeAttribute(node: "match", prefix: ""))
    }

    @Test func aDotOutsideTheConditionsIsNotANodeAttribute() {
        #expect(context("a.le") == .keyword(prefix: "a.le"))
        #expect(context("a:[] ; freq by a.le") == .keyword(prefix: "a.le"))
    }

    @Test func plainWordsAfterTheDoubleColonStayGlobalConditions() {
        #expect(context("a:[] :: dis") == .globalCondition(prefix: "dis"))
    }

    @Test func insideARegexNothingIsOffered() {
        #expect(context("[form=/ab") == .value)
        #expect(context("[form=/a\\/b|c") == .value)
        #expect(context("[form!=/x") == .value)
    }

    @Test func aRegexThatEndedIsOverAndTheNextConditionCanBeTyped() {
        #expect(context("[form=/ab/ & up") == .attributeName(prefix: "up"))
    }

    @Test func afterANegationAnAttributeNameIsOffered() {
        #expect(context("[!") == .attributeName(prefix: ""))
        #expect(context("[word=\"x\" & !") == .attributeName(prefix: ""))
    }

    @Test func regionTagsOfferRegionNamesThenTheirAttributes() {
        #expect(context("<") == .regionName(prefix: ""))
        #expect(context("<te") == .regionName(prefix: "te"))
        #expect(context("</te") == .regionName(prefix: "te"))
        #expect(context("<text ") == .regionAttribute(region: "text", prefix: ""))
        #expect(context("<text gen") == .regionAttribute(region: "text", prefix: "gen"))
        #expect(context("<text genre=\"Book\" ti") == .regionAttribute(region: "text", prefix: "ti"))
    }

    @Test func insideARegionTagsValueNothingIsOffered() {
        #expect(context("<text genre=") == .value)
        #expect(context("<text genre=\"Bo") == .value)
    }

    @Test func aFinishedTagIsOverAndATokenOrKeywordFollows() {
        #expect(context("<s> wit") == .keyword(prefix: "wit"))
        #expect(context("<s> [") == .attributeName(prefix: ""))
    }

    @Test func aLessThanAfterATokenIsStillAnArrowNotATag() {
        #expect(context("[] <") == .keyword(prefix: ""))
    }

    // MARK: Candidates

    @Test func theProviderOffersTheNodesAttributesWithTheirName() {
        let provider = CQLCompletionProvider(corpusInfo: info)
        #expect(provider.candidates(for: .nodeAttribute(node: "a", prefix: "le")) == ["a.lemma"])
        #expect(provider.candidates(for: .nodeAttribute(node: "a", prefix: "fo")) == ["a.form"])
    }

    @Test func theProviderOffersRegionNamesAndTheirAttributes() {
        let provider = CQLCompletionProvider(corpusInfo: info)
        #expect(provider.candidates(for: .regionName(prefix: "")) == ["s", "text"])
        #expect(provider.candidates(for: .regionName(prefix: "te")) == ["text"])
        #expect(provider.candidates(for: .regionAttribute(region: "text", prefix: "")) == ["genre", "title"])
        #expect(provider.candidates(for: .regionAttribute(region: "text", prefix: "ge")) == ["genre"])
        #expect(provider.candidates(for: .regionAttribute(region: "nope", prefix: "")) == nil)
    }

    @Test func conditionsOfferTheNamesTheUserGaveBeforeTheFunctions() {
        let provider = CQLCompletionProvider(corpusInfo: info)
        let offered = provider.candidates(for: .globalCondition(prefix: ""), nodeNames: ["verb", "obj"])
        #expect(offered?.prefix(2) == ["verb", "obj"])
        #expect(offered?.contains("distance") == true)
        #expect(provider.candidates(for: .globalCondition(prefix: "ve"), nodeNames: ["verb", "obj"]) == ["verb"])
    }

    // MARK: Pairing

    @Test func aLessThanOpensATagAfterAClosedTagOrAScopingWord() {
        func typing(_ text: String) -> CQLAutoPairing.Action {
            CQLAutoPairing.action(forTyping: "<", text: text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        }
        #expect(typing("<s> ") == .insert(text: "<>", caretOffset: 1))
        #expect(typing("[] within ") == .insert(text: "<>", caretOffset: 1))
        #expect(typing("[] not ") == .insert(text: "<>", caretOffset: 1))
        #expect(typing("[] ") == .passThrough)
        #expect(typing("[word=\"x\"] ") == .passThrough)
    }

    // MARK: Colours

    private func colors(_ text: String) -> [String: NSColor] {
        let ns = text as NSString
        return Dictionary(CQLQueryField.colorRuns(for: text).map { (ns.substring(with: $0.range), $0.color) }, uniquingKeysWith: { _, last in last })
    }

    @Test func valuesRedKeywordsPurpleOperatorsOrangeTagsTeal() {
        let c = colors(#"<s> [lemma="give" & !(upos=/N.*/)] > [] within <text genre="x"> :: a.form != b.form"#)
        #expect(c[#""give""#] == .systemRed)
        #expect(c["/N.*/"] == .systemRed)
        #expect(c["within"] == .systemPurple)
        #expect(c["="] == .systemOrange)
        #expect(c["!"] == .systemOrange)
        #expect(c[">"] == .systemOrange)
        #expect(c["::"] == .systemOrange)
        #expect(c["!="] == .systemOrange)
        #expect(c["<s>"] == .systemTeal)
        #expect(c[#"<text genre="x">"#] == .systemTeal)
        #expect(c["lemma"] == nil, "attribute names keep the text colour")
    }

    @Test func aKeywordInsideAValueIsAValueAndRelationsAreKeywordsOnlyBeforeABracket() {
        let c = colors(#"[word="within" & child [x="y"] & after="z"]"#)
        #expect(c[#""within""#] == .systemRed)
        #expect(c["within"] == nil)
        #expect(c["child"] == .systemPurple)
        #expect(c["after"] == nil, "here `after` is an attribute")
    }

    @Test func aClosingTagAfterATokenIsTeal() {
        #expect(colors("<s> [] </s>")["</s>"] == .systemTeal)
    }
}
