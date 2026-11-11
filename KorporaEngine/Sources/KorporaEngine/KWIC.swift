import Foundation

/// One token's positional-attribute values within a `KWICLine`. `word` is
/// whichever attribute `ConcordanceHandle.kwicLines` was called with as its
/// primary `kwicAttr` (default "word"); `secondaryAttributes` holds any
/// additional attributes requested via `kwicLines(secondaryAttributes:)`
/// (e.g. "lemma"/"tag"), keyed by attribute name - empty when none were
/// requested.
public struct KWICToken: Sendable, Equatable {
    public let word: String
    public let secondaryAttributes: [String: String]
    /// False for a word that stands between the matched tokens without being one of them (the match column
    /// spans the first to the last matched token, so a pattern with a gap, such as a dependency, has some).
    public let isMatch: Bool

    public init(word: String, secondaryAttributes: [String: String], isMatch: Bool = true) {
        self.word = word
        self.secondaryAttributes = secondaryAttributes
        self.isMatch = isMatch
    }
}

public struct KWICLine: Sendable {
    public let leftTokens: [KWICToken]
    public let kwicTokens: [KWICToken]
    public let rightTokens: [KWICToken]
    /// The match's corpus-wide token start position - stable and meaningful
    /// independent of the `ConcordanceHandle` that produced this
    /// line, so a caller can look up this specific hit's enclosing
    /// structural attributes (e.g. "doc.author") later, on demand, via
    /// `Corpus.structuralAttributeValue(at:attribute:)`, without keeping
    /// anything else alive.
    public let position: Int

    /// Plain space-joined display text, for callers that don't need
    /// per-token/secondary-attribute detail - the whole `KWICLine` API
    /// before secondary attributes existed.
    public var left: String { Self.joined(leftTokens) }
    public var kwic: String { Self.joined(kwicTokens) }
    public var right: String { Self.joined(rightTokens) }

    public init(leftTokens: [KWICToken], kwicTokens: [KWICToken], rightTokens: [KWICToken], position: Int) {
        self.leftTokens = leftTokens
        self.kwicTokens = kwicTokens
        self.rightTokens = rightTokens
        self.position = position
    }

    private static func joined(_ tokens: [KWICToken]) -> String {
        tokens.map(\.word).joined(separator: " ")
    }
}
