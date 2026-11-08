import Cocoa
import KorporaEngine

/// What the caret is sitting in, and therefore what `CQLQueryField` should
/// offer to complete (Phase 6.8).
///
/// Pure syntax, deliberately: it takes a string and an offset and returns a
/// case, with no `Corpus`, no actor and no I/O, so the position logic - the
/// part that's actually easy to get wrong - is unit-testable without a live
/// window or corpus (see `CQLCompletionContextTests`).
///
/// Scope note: this deliberately does **not** complete attribute *values*
/// from the corpus. Completion here is about the CQL language and the
/// corpus's schema (attribute names), both of which are small, fixed and
/// knowable up front - so everything stays synchronous. Value completion
/// would mean reading a lexicon of up to ~700k entries from disk behind an
/// actor, inside AppKit's synchronous completion callback.
enum CQLCompletionContext: Equatable {
    /// Not inside a token bracket - CQL's own keywords (`within`,
    /// `containing`, …) are all that makes sense.
    case keyword(prefix: String)
    /// Inside `[…]`, positioned where an attribute name goes: e.g. the
    /// `lem` of `[lem`.
    case attributeName(prefix: String)
    /// Inside `[…]`, right after an attribute name, where a comparison
    /// operator goes: the caret in `[word ` or `[doc.author `.
    case comparisonOperator(prefix: String)
    /// The caret is where a *value* goes - either inside a quoted string,
    /// or just after a comparison operator with the quote not yet typed.
    /// Nothing is offered either way: values are corpus data (or a regex
    /// over it), not language, so 6.8 deliberately doesn't complete them,
    /// and offering keywords or attribute names here would be actively
    /// wrong.
    case value
    /// After `::`, where global conditions go (`:: distance(a,b) < 5`): pando's functions and the names given to tokens.
    case globalCondition(prefix: String)
    /// After `::`, right after a name and a dot (`:: a.le`): that token's attributes.
    case nodeAttribute(node: String, prefix: String)
    /// Inside `<` or `</`, where the name of a region goes (`<te`).
    case regionName(prefix: String)
    /// Inside a region tag, after its name: the attributes that region has (`<text gen`).
    case regionAttribute(region: String, prefix: String)

    /// Classifies the caret at `partialWordRange` (exactly what
    /// `NSTextView.completions(forPartialWordRange:…)` is handed, i.e.
    /// `rangeForUserCompletion`) within `text`.
    ///
    /// Everything is decided from the tokens *before* the partial word
    /// (`CQLLexer`, a lenient scanner) rather than by parsing the query as a
    /// whole: a query being typed is usually not valid CQL yet - `[word=` has
    /// an unclosed bracket - and a real CQL parser would simply reject it.
    static func at(text: String, partialWordRange: NSRange) -> CQLCompletionContext {
        let ns = text as NSString
        var start = max(0, min(partialWordRange.location, ns.length))
        var length = max(0, min(partialWordRange.length, ns.length - start))

        // AppKit's `rangeForUserCompletion` is *not* just the identifier
        // being typed: when the caret sits right after punctuation it
        // returns that punctuation as the "partial word" - measured on
        // macOS 27, `"["` gives `"["` and `"[word="` gives `"="`. Trimming
        // leading non-identifier characters turns those into an empty
        // prefix at the position after them, which is what the rules below
        // expect.
        //
        // Getting this wrong is what made 6.8 look broken on first
        // click-test: `[` produced prefix `"["`, no keyword starts with
        // `[`, so no popup appeared in the one position where the full
        // attribute list is most useful.
        while length > 0, !isIdentifierCharacter(ns.character(at: start)) {
            start += 1
            length -= 1
        }

        let prefix = ns.substring(with: NSRange(location: start, length: length))
        let before = ns.substring(to: start)

        // What the caret is in is read from the tokens before it (CQLLexer), the same ones the colouring and
        // `QueryNodes` see: a quote, a regex and a region tag are decided in one place.
        let tokens = CQLLexer.tokens(in: before)
        let last = tokens.last
        if let last, last.isUnterminated {
            switch last.kind {
            case .string, .regex: return .value
            case .regionTag: return regionContext(tag: ns.substring(with: last.range), prefix: prefix)
            default: break
            }
        }
        guard CQLLexer.openDepth(after: tokens) > 0 else {
            // Between tokens. After `::` (and before the next `;`) it is a global condition.
            let statement = tokens.reversed().prefix { $0.kind != .semicolon }
            if statement.contains(where: { $0.kind == .doubleColon && $0.depth == 0 }) {
                if let dot = prefix.firstIndex(of: "."), dot != prefix.startIndex {
                    return .nodeAttribute(node: String(prefix[..<dot]), prefix: String(prefix[prefix.index(after: dot)...]))
                }
                return .globalCondition(prefix: prefix)
            }
            return .keyword(prefix: prefix)
        }
        // Inside brackets, the position is decided by the last token before the caret.
        if let last, last.kind == .comparison {
            // `[word=` - the value comes next, so offer nothing rather
            // than a list of attribute names the user can't use here.
            return .value
        }
        if prefix.isEmpty, let last, last.kind == .identifier {
            let word = ns.substring(with: last.range)
            // `[child ` and `[upos="NOUN" & not child `: a `[` comes next.
            if CQLCompletionProvider.restrictionWords.contains(word) { return .value }
            // `[ & not `: another condition or restriction comes next, not an operator.
            if word == "not" { return .attributeName(prefix: prefix) }
        }
        if prefix.isEmpty, let last, last.kind == .identifier || last.kind == .number {
            // `[word ` - a name was just finished, an operator comes next.
            return .comparisonOperator(prefix: prefix)
        }
        return .attributeName(prefix: prefix)
    }

    /// What goes in a region tag still being typed: its name, or after the name one of its attributes (not in a value).
    private static func regionContext(tag: String, prefix: String) -> CQLCompletionContext {
        let body = tag.drop { $0 == "<" || $0 == "/" }
        let name = body.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let afterName = body.dropFirst(name.count)
        guard afterName.first?.isWhitespace == true else { return .regionName(prefix: prefix) }
        // `<text genre=` and `<text genre="Bo`: a value, which isn't completed.
        let trimmed = afterName.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("=") || tag.filter({ $0 == "\"" }).count % 2 == 1 { return .value }
        return .regionAttribute(region: String(name), prefix: prefix)
    }

    private static func isIdentifierCharacter(_ ch: unichar) -> Bool {
        guard let scalar = UnicodeScalar(ch) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "."
    }
}

/// The candidate lists behind `CQLCompletionContext`, for one corpus.
///
/// Fully synchronous by design - see `CQLCompletionContext`'s scope note.
/// The only thing it needs from the corpus is its *schema*, which comes
/// from the corpus's `info()` (read when it is opened),
/// so it's fetched once up front and never touched again.
///
/// `@MainActor` for the mutable `attributeNames` only; the candidate lists
/// and the two pure functions over them are `nonisolated`, both because
/// they touch no state and because a `CQLQueryField` with no provider
/// still needs them from a synchronous AppKit callback.
@MainActor
final class CQLCompletionProvider {
    /// pando-CQL's word-like constructs between tokens: region scoping (`within s`, `containing`,
    /// `having`, `containing subtree`) and `not` (`not within`, `not containing`).
    nonisolated static let regionKeywords = CQLLexer.regionKeywords

    /// The relations written *inside* a token, PML-TQ style: `[upos="NOUN" & child [upos="DET"]]`,
    /// `not child [...]`, `next [...]`. Only directly before a `[` are they relations (an attribute
    /// may also be called `after`), so they are coloured only there.
    nonisolated static let restrictionWords = CQLLexer.restrictionWords

    /// The dependency arrows between two tokens: `A > B` (A is the head of B), `A < B` (A depends on
    /// B), `>>` and `<<` for any distance in the tree, `!>` and `!<` negated.
    nonisolated static let dependencyArrows = [">", "<", ">>", "<<", "!>", "!<"]

    /// What goes after `::` (pando-CQL reference, "Global functions"; dates and locations included).
    nonisolated static let globalFunctions = [
        "century", "day", "decade", "depth", "distabs", "distance", "earliest", "f", "gaps", "geodist", "lat", "latest",
        "lon", "match", "month", "nchildren", "ndescendants", "nvals", "strlen", "tcnt", "week", "year",
    ]

    /// Comparison operators, matching the set `CQLQueryField.recolor`
    /// highlights. Offered right after an attribute name, where they're the
    /// only thing that can legally come next - and where there's no partial
    /// word to type them into, which is why they're completion candidates
    /// rather than something you'd only ever type by hand.
    nonisolated static let comparisonOperators = ["=", "!=", "<", ">"]

    private(set) var attributeNames: [String] = []
    /// The attributes of each region (`text`: genre, title), for the tags `<text gen`.
    private(set) var structureAttributes: [String: [String]] = [:]

    /// For an owner that has to look the corpus up itself (the query bar,
    /// the Filter sheet).
    init(corpusName: String) {
        prefetchAttributeNames(corpusName: corpusName)
    }

    /// For an owner that already has `info()` in hand - the New Concordance
    /// sheet fetches it anyway to fill its info label, so re-fetching would
    /// be pure waste.
    init(corpusInfo: CorpusInfo) {
        attributeNames = Self.attributeNames(from: corpusInfo)
        structureAttributes = Self.structureAttributes(from: corpusInfo)
    }

    nonisolated static func structureAttributes(from info: CorpusInfo) -> [String: [String]] {
        Dictionary(info.structures.map { ($0.name, $0.attributes.sorted()) }, uniquingKeysWith: { first, _ in first })
    }

    /// Both kinds of attribute name, which is what makes this useful for real queries: the
    /// token attributes verbatim (`form`, `lemma`, `upos`) plus the text properties in pando's
    /// `structure_attribute` form (`doc_author`, `s_sent_id`), which pando-CQL accepts inside
    /// `[…]`. A structure with a great many attributes (UD's sentence translations, `s_text_xx`)
    /// contributes only its first few, so they don't bury the useful names.
    ///
    /// Sorted, since a completion popup is read by eye.
    nonisolated static func attributeNames(from info: CorpusInfo) -> [String] {
        let structural = info.structures.flatMap { structure in
            structure.attributes.prefix(40).map { "\(structure.name)_\($0)" }
        }
        return (info.attributes + structural).sorted()
    }

    /// Candidates for `context`, or nil when there's nothing to offer.
    /// `nodeNames`: the names the user gave to tokens, which `::` conditions refer to.
    func candidates(for context: CQLCompletionContext, nodeNames: [String] = []) -> [String]? {
        switch context {
        case .nodeAttribute(let node, let prefix):
            return Self.matching(attributeNames, prefix: prefix)?.map { "\(node).\($0)" }
        case .regionName(let prefix):
            return Self.matching(structureAttributes.keys.sorted(), prefix: prefix)
        case .regionAttribute(let region, let prefix):
            return Self.matching(structureAttributes[region] ?? [], prefix: prefix)
        case .keyword(let prefix):
            return Self.matching(Self.regionKeywords + Self.dependencyArrows, prefix: prefix)
        case .attributeName(let prefix):
            return Self.matching(attributeNames + Self.restrictionWords, prefix: prefix)
        case .globalCondition(let prefix):
            return Self.matching(nodeNames + Self.globalFunctions, prefix: prefix)
        case .comparisonOperator(let prefix):
            return Self.matching(Self.comparisonOperators, prefix: prefix)
        case .value:
            return nil
        }
    }

    /// Prefix-matched case-insensitively; an empty prefix offers
    /// everything, which is what makes the caret right after `[` (or after
    /// an attribute name) useful rather than dead.
    ///
    /// Returns nil when the only match is the prefix itself: there is
    /// nothing left to complete, and since completion now fires
    /// automatically as you type (see `CQLQueryField.textDidChange`), a
    /// popup offering `word` for `[word` would just be in the way.
    nonisolated static func matching(_ candidates: [String], prefix: String) -> [String]? {
        guard !prefix.isEmpty else { return candidates.isEmpty ? nil : candidates }
        let lowered = prefix.lowercased()
        let matches = candidates.filter { $0.lowercased().hasPrefix(lowered) }
        if matches.count == 1, matches[0].lowercased() == lowered { return nil }
        return matches.isEmpty ? nil : matches
    }

    private func prefetchAttributeNames(corpusName: String) {
        guard !corpusName.isEmpty else { return }
        Task { @MainActor [weak self] in
            do {
                let corpus = try await Engines.default.openCorpus(name: corpusName)
                let info = try await corpus.info()
                self?.attributeNames = Self.attributeNames(from: info)
                self?.structureAttributes = Self.structureAttributes(from: info)
            } catch {
                // Completion is an optional convenience - a corpus that
                // can't be opened or read just means no attribute
                // candidates, never an error in the user's face while
                // they're typing.
                self?.attributeNames = []
            }
        }
    }
}

/// Auto-closing brackets and quotes for `CQLQueryField` (Phase 6.8): type
/// `[` and get `[]` with the caret inside, type the closing character when
/// it's already there and step over it instead of doubling it.
///
/// Pure functions over (text, selection, typed character) so the rules are
/// unit-testable without a text view - the same reason
/// `CQLCompletionContext` is separate from the field.
enum CQLAutoPairing {
    /// Left-right pairs CQL actually uses: token brackets, quoted values,
    /// grouping parens, and structure tags.
    static let pairs: [Character: Character] = ["[": "]", "\"": "\"", "(": ")", "<": ">"]

    /// The closing halves, which is what "step over instead of inserting"
    /// keys off. `"` is deliberately both an opener and a closer - the same
    /// character does both jobs, so which one it is depends entirely on
    /// what's to the right of the caret.
    static var closers: Set<Character> { Set(pairs.values) }

    enum Action: Equatable {
        /// Replace the selection with `text`, then put the caret
        /// `caretOffset` characters into it. Auto-pairing always uses an
        /// offset that lands *between* the two halves.
        case insert(text: String, caretOffset: Int)
        /// The typed character is already the next one - move the caret
        /// past it rather than inserting a duplicate.
        case moveOver
        /// Nothing special; let `NSTextView` insert it normally.
        case passThrough
    }

    static func action(forTyping input: String, text: String, selectedRange: NSRange) -> Action {
        guard input.count == 1, let character = input.first else { return .passThrough }
        let ns = text as NSString
        let caret = max(0, min(selectedRange.location, ns.length))

        // Wrap a selection rather than replacing it: selecting `fox` and
        // typing `"` should give `"fox"`, which is the one case where the
        // caret offset is not 1.
        if selectedRange.length > 0, let close = pairs[character] {
            let selected = ns.substring(with: NSRange(
                location: caret, length: min(selectedRange.length, ns.length - caret)))
            return .insert(text: "\(character)\(selected)\(close)", caretOffset: 1 + selected.count)
        }

        // Step over an existing closer. Checked before the opener case so
        // that `"` closes a string it's sitting at the end of instead of
        // opening a new one.
        if closers.contains(character), caret < ns.length,
           ns.character(at: caret) == character.utf16.first {
            return .moveOver
        }

        if let close = pairs[character] {
            // `<` opens a structure tag (`<s>`) only where an operand can start. After an operand it is an
            // operator - a dependency (`[] < []`, `!<`, `<<`) or a comparison (`[freq < 5]`) - so no `>` follows.
            if character == "<", followsOperand(text: ns, caret: caret) { return .passThrough }
            return .insert(text: "\(character)\(close)", caretOffset: 1)
        }
        return .passThrough
    }

    /// Whether what is before the caret ends an operand: a token, a value, a name, or an operator half such as `!`
    /// (so `<<` is not paired). After a region tag or a scoping word (`within `) a `<` opens a tag again.
    private static func followsOperand(text: NSString, caret: Int) -> Bool {
        let before = text.substring(to: caret)
        return CQLLexer.endsOperand(CQLLexer.tokens(in: before).last, text: before)
    }

    /// Whether backspace should delete both halves of an empty pair - the
    /// caret sitting in `[|]` or `"|"`, which is exactly what's left after
    /// auto-pairing something and changing your mind.
    static func deletesEmptyPair(text: String, selectedRange: NSRange) -> Bool {
        guard selectedRange.length == 0 else { return false }
        let ns = text as NSString
        let caret = selectedRange.location
        guard caret > 0, caret < ns.length else { return false }
        guard let open = Character(utf16: ns.character(at: caret - 1)),
              let close = Character(utf16: ns.character(at: caret)) else { return false }
        return pairs[open] == close
    }
}

extension Character {
    /// Nil for an unpaired surrogate, which can't be a bracket or quote
    /// anyway - so callers can treat nil as "not a pair character".
    fileprivate init?(utf16 unit: unichar) {
        guard let scalar = UnicodeScalar(unit) else { return nil }
        self = Character(scalar)
    }
}
