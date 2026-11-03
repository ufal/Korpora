import AppKit
import Foundation
import KorporaEngine
import Testing

@testable import Korpora

/// Phase 6.8: where the caret is decides what gets completed.
///
/// **These tests drive a real `NSTextView`** and read its
/// `rangeForUserCompletion`, rather than computing the partial-word range
/// themselves. That is deliberate, and it is the whole reason the first
/// version of 6.8 shipped broken:
///
/// The original tests built the range arithmetically as
/// `length - prefix.length`, i.e. they asserted the parser against ranges
/// *invented to match the parser's own assumptions*. AppKit doesn't behave
/// that way - when the caret sits right after punctuation it returns the
/// punctuation as the partial word (`"["` → `"["`, `"[word="` → `"="`), so
/// 18 green tests said nothing about whether completion actually worked.
/// It didn't: the two most useful positions offered nothing at all.
///
/// Taking the range from AppKit means these tests fail if that behaviour
/// ever differs from what the parser expects, which is the only thing
/// worth asserting here.
@MainActor
struct CQLCompletionContextTests {
    /// Context for `text` with the caret at the very end, using AppKit's
    /// own idea of the partial word.
    private func context(_ text: String) -> CQLCompletionContext {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return CQLCompletionContext.at(text: text, partialWordRange: textView.rangeForUserCompletion)
    }

    // MARK: - the two positions that were broken

    /// Right after `[`, AppKit reports the partial word as `"["`. Trimming
    /// that punctuation is what turns this into "offer every attribute",
    /// which is the single most useful moment for completion.
    @Test func justInsideABracketOffersAttributeNames() {
        #expect(context("[") == .attributeName(prefix: ""))
    }

    /// Right after `=`, AppKit reports the partial word as `"="`. The
    /// value comes next, and 6.8 doesn't complete values - so this must be
    /// `.value` (nothing), not a list of attribute names that can't go
    /// there.
    @Test func rightAfterAnOperatorOffersNothing() {
        #expect(context("[word=") == .value)
        #expect(context("[word !=") == .value)
        #expect(context("[doc.author = ") == .value)
    }

    // MARK: - keywords

    @Test func plainWordOutsideBracketsIsAKeyword() {
        #expect(context("wit") == .keyword(prefix: "wit"))
    }

    @Test func wordAfterAClosedBracketIsAKeyword() {
        #expect(context(#"[word="fox"] wit"#) == .keyword(prefix: "wit"))
    }

    // MARK: - attribute names

    @Test func partialWordInsideABracketIsAnAttributeName() {
        #expect(context("[lem") == .attributeName(prefix: "lem"))
    }

    /// A second attribute in the same bracket: the closed quote must not
    /// leave the parser thinking it's still in a value, and `&` must not
    /// read as a finished identifier.
    @Test func attributeNameAfterACompletedValueInTheSameBracket() {
        #expect(context(#"[word="fox" & ta"#) == .attributeName(prefix: "ta"))
    }

    @Test func afterABooleanOperatorOffersAttributeNames() {
        #expect(context(#"[word="fox" & "#) == .attributeName(prefix: ""))
    }

    /// Nested/adjacent brackets: the *last* unclosed one is what counts.
    @Test func secondBracketAfterAClosedOneIsAnAttributeName() {
        #expect(context(#"[word="fox"][ta"#) == .attributeName(prefix: "ta"))
    }

    // MARK: - comparison operators

    /// A finished name followed by a space: an operator is the only thing
    /// that can legally come next, and there's no partial word to type it
    /// into - which is exactly why offering it is worth doing.
    @Test func afterAFinishedAttributeNameOffersOperators() {
        #expect(context("[word ") == .comparisonOperator(prefix: ""))
        #expect(context("[doc.author ") == .comparisonOperator(prefix: ""))
    }

    /// Without the space, AppKit hands back the whole identifier, so this
    /// is still name position - the name might not be finished yet.
    @Test func withoutASpaceItIsStillNamePosition() {
        #expect(context("[word") == .attributeName(prefix: "word"))
    }

    // MARK: - inside a quoted value: nothing

    @Test func insideAnOpenQuoteOffersNothing() {
        #expect(context(#"[word="fo"#) == .value)
        #expect(context(#"[lemma=""#) == .value)
    }

    /// An escaped quote inside a value doesn't close it - otherwise
    /// everything after it would be misread as language.
    @Test func escapedQuoteInsideAValueDoesNotCloseIt() {
        #expect(context(#"[word="say \"he"#) == .value)
    }

    /// The unbracketed form the "New Subcorpus…" popover uses.
    @Test func unbracketedQuotedValueOffersNothing() {
        #expect(context(#"author="Tw"#) == .value)
    }

    // MARK: - robustness

    /// A range past the end of the string, which a stale completion
    /// request after an edit can produce, must clamp rather than trap.
    @Test func outOfBoundsRangeIsClampedNotFatal() {
        let result = CQLCompletionContext.at(
            text: "[word", partialWordRange: NSRange(location: 99, length: 40))
        #expect(result == .comparisonOperator(prefix: ""))
    }

    @Test func emptyTextIsAKeywordContext() {
        #expect(context("") == .keyword(prefix: ""))
    }
}

/// The candidate lists themselves - in particular that structural
/// attributes are offered in the dotted form CQL actually accepts.
@MainActor
struct CQLCompletionCandidateTests {
    private let info = CorpusInfo(
        name: "test", sizeTokens: 17, attributes: ["word", "lemma", "tag"],
        structures: [
            StructureInfo(name: "doc", attributes: ["id", "author"]),
            StructureInfo(name: "s", attributes: []),
        ])

    @Test func bothPositionalAndStructuralNamesAreOffered() {
        #expect(
            CQLCompletionProvider.attributeNames(from: info)
                == ["doc_author", "doc_id", "lemma", "tag", "word"])
    }

    /// A structure with no attributes of its own contributes nothing -
    /// there's no `s.` to complete to.
    @Test func aStructureWithNoAttributesContributesNothing() {
        #expect(!CQLCompletionProvider.attributeNames(from: info).contains { $0.hasPrefix("s.") })
    }

    @Test func emptyPrefixOffersEverything() {
        #expect(CQLCompletionProvider.matching(["word", "lemma"], prefix: "") == ["word", "lemma"])
    }

    @Test func prefixMatchingIsCaseInsensitive() {
        #expect(
            CQLCompletionProvider.matching(["doc.author", "doc.id", "word"], prefix: "DOC.")
                == ["doc.author", "doc.id"])
    }

    @Test func noMatchesIsNilSoAppKitShowsNoPopup() {
        #expect(CQLCompletionProvider.matching(["word"], prefix: "zz") == nil)
    }

    /// Nothing left to complete means no popup. Matters now that
    /// completion fires automatically: a popup offering only `word` while
    /// you're typing `[word` would just be in the way.
    @Test func aSoleExactMatchOffersNoPopup() {
        #expect(CQLCompletionProvider.matching(["word", "lemma"], prefix: "word") == nil)
        #expect(CQLCompletionProvider.matching(["word", "lemma"], prefix: "WORD") == nil)
    }

    /// But an exact match that is also a prefix of something else still
    /// offers the longer one.
    @Test func anExactMatchThatIsAlsoAPrefixStillOffersTheLongerCandidate() {
        #expect(CQLCompletionProvider.matching(["doc", "doc.id"], prefix: "doc") == ["doc", "doc.id"])
    }
}

/// End-to-end through the real field: text in, candidate list out, using
/// AppKit's own partial-word range. This is the layer the original 6.8
/// tests skipped entirely, and where its bug lived.
@MainActor
struct CQLQueryFieldCompletionTests {
    private func field(withCorpusSchema: Bool) -> CQLQueryField {
        let field = CQLQueryField(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        if withCorpusSchema {
            field.completionProvider = CQLCompletionProvider(
                corpusInfo: CorpusInfo(
                    name: "test", sizeTokens: 17, attributes: ["word", "lemma", "tag"],
                    structures: [StructureInfo(name: "doc", attributes: ["id", "author"])]))
        }
        return field
    }

    private func candidates(_ text: String, withCorpusSchema: Bool = true) -> [String]? {
        let field = field(withCorpusSchema: withCorpusSchema)
        field.text = text
        field.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return field.textView.candidates(
            forPartialWordRange: field.textView.rangeForUserCompletion)
    }

    /// The regression the click-test caught: typing `[` offered nothing.
    @Test func typingAnOpenBracketOffersEveryAttributeName() {
        #expect(candidates("[") == ["doc_author", "doc_id", "lemma", "tag", "word"] + CQLCompletionProvider.restrictionWords)
    }

    @Test func aPartialAttributeNameNarrowsTheList() {
        #expect(candidates("[l") == ["lemma"])
        #expect(candidates("[doc_") == ["doc_author", "doc_id"])
    }

    @Test func afterAnAttributeNameAndSpaceOffersOperators() {
        #expect(candidates("[word ") == ["=", "!=", "<", ">"])
    }

    @Test func rightAfterAnOperatorOffersNothing() {
        #expect(candidates("[word=") == nil)
    }

    @Test func insideAQuotedValueOffersNothing() {
        #expect(candidates(#"[word="fo"#) == nil)
    }

    @Test func keywordsCompleteOutsideBrackets() {
        #expect(candidates("wit") == ["within"])
    }

    /// A field with no corpus still completes the language half - that's
    /// what lets owners be wired independently.
    @Test func withoutACorpusKeywordsStillWorkButNamesDoNot() {
        #expect(candidates("wit", withCorpusSchema: false) == ["within"])
        #expect(candidates("[word ", withCorpusSchema: false) == ["=", "!=", "<", ">"])
        #expect(candidates("[", withCorpusSchema: false) == CQLCompletionProvider.restrictionWords)
        #expect(candidates("[lem", withCorpusSchema: false) == nil)
    }

    // MARK: Dependency relations and global conditions (pando-CQL)

    /// After a closed token the arrows are offered with the region words.
    @Test func betweenTokensTheDependencyArrowsAreOffered() {
        let all = candidates(#"[upos="NOUN"] "#)
        #expect(all == CQLCompletionProvider.regionKeywords + CQLCompletionProvider.dependencyArrows)
        #expect(Set([">", "<", ">>", "<<", "!>", "!<"]).isSubset(of: Set(all ?? [])))
        #expect(candidates(#"[upos="NOUN"] c"#) == ["containing"])
    }

    /// Inside a token, after `&`, the relations are offered next to the attribute names.
    @Test func insideATokenTheRestrictionWordsComeWithTheNames() {
        let all = candidates(#"[upos="NOUN" & "#)
        #expect(all == ["doc_author", "doc_id", "lemma", "tag", "word"] + CQLCompletionProvider.restrictionWords)
        #expect(candidates(#"[upos="NOUN" & ch"#) == ["child"])
        #expect(candidates(#"[upos="NOUN" & not "#)?.contains("child") == true)
    }

    /// A restriction is followed by `[`, not by an operator or a name.
    @Test func afterARestrictionWordNothingIsOffered() {
        #expect(candidates(#"[upos="NOUN" & child "#) == nil)
        #expect(candidates("[parent ") == nil)
    }

    /// The nested token is closed, but the outer one is still open: names, not region words.
    @Test func nestingIsFollowedAcrossInnerBrackets() {
        let names = candidates(#"[upos="NOUN" & child [upos="DET"] & "#)
        #expect(names?.contains("lemma") == true && names?.contains("within") == false)
        // and inside the inner one, as well
        #expect(candidates(#"[upos="NOUN" & child [lem"#) == ["lemma"])
    }

    /// Brackets inside a quoted value or a /regex/ don't count.
    @Test func bracketsInValuesDoNotOpenTokens() {
        #expect(candidates(#"[word="[a-z]+"] "#)?.contains("within") == true)
        #expect(candidates(#"[word=/[a-z]+/] "#)?.contains("within") == true)
    }

    @Test func afterDoubleColonTheGlobalFunctionsAreOffered() {
        #expect(candidates(#"a:[] b:[] :: dist"#) == ["distabs", "distance"])
        #expect(candidates(#"a:[] :: "#) == CQLCompletionProvider.globalFunctions)
        #expect(candidates(#"a:[] :: ndesc"#) == ["ndescendants"])
        // The language half needs no corpus.
        #expect(candidates(#"a:[] :: str"#, withCorpusSchema: false) == ["strlen"])
        // A new command after `;` is between tokens again.
        #expect(candidates(#"a:[] :: a != b; wit"#) == ["within"])
    }

    /// The restriction words are only coloured as keywords directly before a `[`.
    @Test func restrictionWordsAreColouredOnlyBeforeABracket() throws {
        let regex = try NSRegularExpression(pattern: CQLCompletionProvider.keywordPattern)
        func matches(_ query: String) -> [String] {
            let ns = query as NSString
            return regex.matches(in: query, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        #expect(matches(#"[upos="NOUN" & child [upos="DET"]]"#) == ["child"])
        #expect(matches(#"[after="x"]"#).isEmpty)
        #expect(matches(#"[upos="ADJ" & not next [upos="NOUN"]] within s"#) == ["not", "next", "within"])
    }
}
