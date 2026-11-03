import Foundation

/// Where a sort key is read from, relative to a concordance hit: the match
/// itself, the tokens to its left (nearest first) or to its right.
public enum SortAnchor: Sendable, Codable, Equatable {
    case left, kwic, right
}

/// One level of a (possibly multi-level) sort. `span` is how many tokens of
/// context to read the key from; ignored for `.kwic`, which - mirroring
/// KonText - always sorts on just the match's first token, since a KWIC
/// match's own length varies.
public struct SortLevel: Sendable, Codable {
    public var attribute: String
    public var anchor: SortAnchor
    public var span: Int
    public var caseInsensitive: Bool
    /// Manatee's "retrograde" option (the `r` flag) - compares each word
    /// spelled backwards, e.g. to sort by word ending/suffix rather than by
    /// word start. Not a sort-direction toggle; every sort is ascending.
    public var reverse: Bool

    public init(attribute: String, anchor: SortAnchor, span: Int = 1,
                caseInsensitive: Bool = false, reverse: Bool = false) {
        self.attribute = attribute
        self.anchor = anchor
        self.span = max(span, 1)
        self.caseInsensitive = caseInsensitive
        self.reverse = reverse
    }
}

/// A sort key made of up to 4 levels (KonText's multi-level cap).
public struct SortCriteria: Sendable, Codable {
    public var levels: [SortLevel]

    public init(levels: [SortLevel]) {
        precondition(!levels.isEmpty, "SortCriteria needs at least one level")
        self.levels = Array(levels.prefix(4))
    }

    public init(_ level: SortLevel) {
        self.init(levels: [level])
    }
}
