import Foundation

/// One token (`[...]`) of a pando-CQL query: a node a frequency or a collocation can be taken from
/// (docs/frequency-composer.md).
public struct QueryNode: Equatable, Sendable {
    /// Its place among the query's tokens, from 0. A hit's `tokens` are in this order.
    public let index: Int
    /// From the name (when there is one) to the closing bracket, in UTF-16 units of the query text.
    public let range: NSRange
    /// The brackets alone, `[` to `]`.
    public let bracketRange: NSRange
    /// The name the user wrote in front of it (`verb:[...]`).
    public let userName: String?
    /// The name pando knows it by: the user's, else one chosen for it (a, b, c...).
    public let name: String
    /// What follows the closing bracket: `*`, `+`, `?` or `{1,2}`. Such a node may match several tokens or
    /// none, so a hit's tokens no longer line up with the nodes.
    public let repeatMark: String?

    /// A node a frequency can be taken from: one token, always there.
    public var isPickable: Bool { repeatMark == nil }
}

/// The tokens of a pando-CQL query, found by a small scanner (not a parser): `[` at the top level starts
/// one, and brackets or `]` inside quoted and `/regex/` values and inside a token's own conditions
/// (`[parent [upos="NOUN"]]`) don't. Regions (`<s>`, `</text>`), dependency arrows, `::` conditions and
/// everything after a `;` are not nodes.
public struct QueryNodes: Equatable, Sendable {
    public let text: String
    public let nodes: [QueryNode]
    /// Set when the text isn't plain pando-CQL (a dialect keyword first), so the nodes can't be trusted.
    public let unsupportedReason: String?

    /// Names that would clash with something else pando reads after `::` (a region, `match`).
    private static let reserved: Set<String> = ["s", "p", "t", "text", "doc", "match", "matchend"]
    private static let dialects: Set<String> = ["MANATEE", "PMLTQ", "CWB", "TIGER"]

    public init(_ text: String) {
        self.text = text
        let ns = text as NSString
        let first = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        if Self.dialects.contains(first.uppercased()), first == first.uppercased() {
            nodes = []
            unsupportedReason = "The query is written in the \(first.capitalized) dialect."
            return
        }
        unsupportedReason = nil

        struct Found { var nameRange: NSRange?; var userName: String?; var bracket: NSRange }
        var found: [Found] = []
        let tokens = CQLLexer.tokens(in: text)
        var k = 0
        scan: while k < tokens.count {
            let token = tokens[k]
            switch token.kind {
            case .semicolon, .doubleColon where token.depth == 0:
                break scan
            case .openBracket where token.depth == 0:
                // To the `]` that closes it (or the end of the text, while it is being typed).
                var close = k + 1
                while close < tokens.count, !(tokens[close].kind == .closeBracket && tokens[close].depth == 0) { close += 1 }
                let end = close < tokens.count ? tokens[close].end : ns.length
                // A name is `identifier:` right before the bracket, with nothing between.
                var nameRange: NSRange?
                var userName: String?
                if k >= 2, tokens[k - 1].kind == .colon, tokens[k - 1].end == token.range.location,
                   tokens[k - 2].kind == .identifier, tokens[k - 2].end == tokens[k - 1].range.location {
                    let name = ns.substring(with: tokens[k - 2].range)
                    if let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) {
                        nameRange = NSRange(location: tokens[k - 2].range.location, length: token.range.location - tokens[k - 2].range.location)
                        userName = name
                    }
                }
                found.append(Found(nameRange: nameRange, userName: userName,
                                   bracket: NSRange(location: token.range.location, length: end - token.range.location)))
                k = close + 1
            default:
                k += 1
            }
        }

        var taken = Set(found.compactMap(\.userName))
        var counter = 0
        func freshName() -> String {
            while true {
                let letter = String(UnicodeScalar(UInt8(97 + counter % 26)))
                let candidate = counter < 26 ? letter : "\(letter)\(counter / 26)"
                counter += 1
                if !taken.contains(candidate), !Self.reserved.contains(candidate) {
                    taken.insert(candidate)
                    return candidate
                }
            }
        }
        nodes = found.enumerated().map { offset, item in
            let end = item.bracket.location + item.bracket.length
            let start = item.nameRange?.location ?? item.bracket.location
            let mark = tokens.first { $0.kind == .repeatMark && $0.range.location == end }.map { ns.substring(with: $0.range) }
            return QueryNode(index: offset,
                             range: NSRange(location: start, length: end - start),
                             bracketRange: item.bracket,
                             userName: item.userName,
                             name: item.userName ?? freshName(),
                             repeatMark: mark)
        }
    }

    /// The query with `name:` put in front of every token that has none: what is sent to pando when a
    /// frequency or a collocation refers to a node.
    public func textWithNames() -> String {
        var result = text as NSString
        for node in nodes.reversed() where node.userName == nil {
            result = result.replacingCharacters(in: NSRange(location: node.bracketRange.location, length: 0),
                                                with: "\(node.name):") as NSString
        }
        return result as String
    }
}
