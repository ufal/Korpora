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
        var index = 0
        let length = ns.length
        func char(_ i: Int) -> Character? {
            i >= 0 && i < length ? Character(UnicodeScalar(ns.character(at: i)) ?? " ") : nil
        }
        outer: while index < length {
            guard let ch = char(index) else { break }
            switch ch {
            case ";":
                break outer
            case ":" where char(index + 1) == ":":
                break outer
            case "\"":
                index = Self.endOfQuote(in: ns, from: index)
            case "<":
                index = Self.endOfRegion(in: ns, from: index) ?? index + 1
            case "[":
                let end = Self.endOfToken(in: ns, from: index)
                // A name is `identifier:` right before the bracket, and not the second colon of `::`.
                var nameRange: NSRange?
                var userName: String?
                if char(index - 1) == ":", char(index - 2) != ":" {
                    var start = index - 1
                    while let c = char(start - 1), c.isLetter || c.isNumber || c == "_" { start -= 1 }
                    if start < index - 1, let c = char(start), !c.isNumber {
                        nameRange = NSRange(location: start, length: index - start)
                        userName = ns.substring(with: NSRange(location: start, length: index - 1 - start))
                    }
                }
                found.append(Found(nameRange: nameRange, userName: userName,
                                   bracket: NSRange(location: index, length: end - index)))
                index = end
            default:
                index += 1
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
            let mark = Self.repeatMark(in: ns, at: end)
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

    // MARK: Scanning

    /// The index after the closing quote of the string that opens at `start` (a backslash keeps the next
    /// character literal).
    private static func endOfQuote(in ns: NSString, from start: Int) -> Int {
        var i = start + 1
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x5C { i += 2; continue }
            if c == 0x22 { return i + 1 }
            i += 1
        }
        return ns.length
    }

    /// The index after the `]` that closes the token opening at `start`.
    private static func endOfToken(in ns: NSString, from start: Int) -> Int {
        var depth = 0
        var i = start
        var previous: unichar = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x5C { i += 2; continue }
            if c == 0x22 { i = endOfQuote(in: ns, from: i); previous = 0x22; continue }
            if c == 0x2F, previous == 0x3D {            // `=/regex/`
                i += 1
                while i < ns.length {
                    let r = ns.character(at: i)
                    if r == 0x5C { i += 2; continue }
                    if r == 0x2F { break }
                    i += 1
                }
                i += 1; previous = 0x2F; continue
            }
            if c == 0x5B { depth += 1 }
            if c == 0x5D { depth -= 1; if depth == 0 { return i + 1 } }
            if c != 0x20, c != 0x09, c != 0x0A { previous = c }
            i += 1
        }
        return ns.length
    }

    /// For `<` that opens a region (`<s>`, `<text genre="Book">`, `</s>`): the index after its `>`.
    /// A `<` that is a dependency arrow (`[] < []`, `a <b:[...]`) has a `[` or `:` before any `>`.
    private static func endOfRegion(in ns: NSString, from start: Int) -> Int? {
        var i = start + 1
        guard i < ns.length else { return nil }
        let first = ns.character(at: i)
        let isLetter = (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first)
        guard isLetter || first == 0x2F else { return nil }
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x22 { i = endOfQuote(in: ns, from: i); continue }
            if c == 0x5B || c == 0x3A || c == 0x3B { return nil }
            if c == 0x3E { return i + 1 }
            i += 1
        }
        return nil
    }

    /// `*`, `+`, `?` or `{n}`, `{n,}`, `{n,m}` right after a token.
    private static func repeatMark(in ns: NSString, at index: Int) -> String? {
        guard index < ns.length else { return nil }
        let c = ns.character(at: index)
        if c == 0x2A || c == 0x2B || c == 0x3F { return ns.substring(with: NSRange(location: index, length: 1)) }
        guard c == 0x7B else { return nil }
        var i = index + 1
        while i < ns.length {
            let d = ns.character(at: i)
            if d == 0x7D { return ns.substring(with: NSRange(location: index, length: i + 1 - index)) }
            guard (0x30...0x39).contains(d) || d == 0x2C || d == 0x20 else { return nil }
            i += 1
        }
        return nil
    }
}
