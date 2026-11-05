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

    public init(word: String, secondaryAttributes: [String: String]) {
        self.word = word
        self.secondaryAttributes = secondaryAttributes
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
