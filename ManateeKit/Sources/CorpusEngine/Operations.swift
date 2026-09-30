import Foundation

/// Where a sort key is read from, relative to a concordance hit - matches
/// Manatee's own sort-context convention (`-1<0` = left, `0<0~0>0` = the
/// match itself, `1>0` = right; see conccrit.cc/concctx.cc).
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

/// A sort key made of up to 4 levels, matching KonText's own multi-level
/// sort cap (manatee's grammar itself has no such limit, but there's no
/// reason to expose more than KonText's proven UI does).
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

/// Which match, within a filter's context window, to test - see
/// `Concordance::set_collocation`'s `rank` parameter (concord.cc): counted
/// from the left if positive, from the right if negative.
public enum MatchRank: Sendable, Codable {
    case first, last
}

/// A positive/negative sub-filter: keep or drop concordance lines depending
/// on whether `query` matches somewhere in [leftOffset, rightOffset] tokens
/// around each hit. Mirrors KonText's filter form exactly (including its
/// -5/5 default window) rather than a redesigned model.
public struct PNFilterSpec: Sendable, Codable {
    public var positive: Bool
    public var leftOffset: Int
    public var rightOffset: Int
    public var rank: MatchRank
    public var includeKwic: Bool
    public var query: String

    public init(positive: Bool, leftOffset: Int = -5, rightOffset: Int = 5,
                rank: MatchRank = .first, includeKwic: Bool = true, query: String) {
        self.positive = positive
        self.leftOffset = leftOffset
        self.rightOffset = rightOffset
        self.rank = rank
        self.includeKwic = includeKwic
        self.query = query
    }
}
