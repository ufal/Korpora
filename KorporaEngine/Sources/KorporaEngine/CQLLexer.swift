import Foundation

/// One lexical piece of a pando-CQL text.
public struct CQLToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `"..."`. Not terminated: the text ends inside it (the caret is in a value).
        case string(terminated: Bool)
        /// `/.../` after `=` or `!=`.
        case regex(terminated: Bool)
        /// A name: letters, digits, `_` and dots (`lemma`, `doc.author`, `a.lemma`, `within`).
        case identifier
        case number
        case openBracket, closeBracket, openParen, closeParen
        /// `=`, `!=`, `<=`, `>=`, and `<`, `>` inside a token's brackets.
        case comparison
        /// `>`, `<`, `>>`, `<<`, `!>`, `!<` between tokens: the dependency arrows.
        case arrow
        /// `!` before a condition.
        case negation
        /// `&` and `|`.
        case logic
        /// The colon after a node's name: `a:[...]`.
        case colon
        /// `::`, which starts the conditions on the whole match.
        case doubleColon
        /// `=:`, which names a query.
        case assignment
        case semicolon
        /// `<s>`, `</text>`, `<text genre="Book">`. Not terminated: the text ends inside the tag.
        case regionTag(terminated: Bool)
        /// `*`, `+`, `?`, `{1,2}` right after a token.
        case repeatMark
        case other
    }

    public var kind: Kind
    /// UTF-16 units of the text.
    public var range: NSRange
    /// The brackets that contain it (0: between tokens). A `[` has the depth outside it, a `]` too.
    public var depth: Int

    public var end: Int { range.location + range.length }

    /// A string, regex or region tag the text ends inside.
    public var isUnterminated: Bool {
        switch kind {
        case .string(let terminated), .regex(let terminated), .regionTag(let terminated): return !terminated
        default: return false
        }
    }
}

/// A lenient scanner for pando-CQL: it never fails and never needs the query to be complete, because it is used
/// on text being typed. It says what each piece is (and where), not whether the query is valid: pando decides that.
/// `QueryNodes`, the completion, the auto-pairing and the colouring all read the same tokens, so they agree about
/// what a quote, a regex or a region tag is.
public enum CQLLexer {
    /// Words that scope a query to a region or negate a scope (`within s`, `not containing`).
    public static let regionKeywords = ["within", "containing", "having", "subtree", "not"]
    /// The relations written inside a token, only meant before a `[`: `[upos="NOUN" & child [upos="DET"]]`.
    public static let restrictionWords = ["child", "parent", "ancestor", "descendant", "sibling", "next", "prev", "after", "before"]

    public static func tokens(in text: String) -> [CQLToken] {
        let ns = text as NSString
        let length = ns.length
        var tokens: [CQLToken] = []
        var depth = 0
        var i = 0

        func unit(_ index: Int) -> unichar? { index >= 0 && index < length ? ns.character(at: index) : nil }
        func add(_ kind: CQLToken.Kind, _ start: Int, _ end: Int, depth: Int? = nil) {
            tokens.append(CQLToken(kind: kind, range: NSRange(location: start, length: end - start), depth: depth ?? 0))
        }
        func isLetterOrDigit(_ c: unichar) -> Bool {
            guard let scalar = UnicodeScalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        func isIdentifierUnit(_ c: unichar) -> Bool { isLetterOrDigit(c) || c == 0x5F || c == 0x2E }

        while i < length {
            let c = ns.character(at: i)
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1

            case 0x22:  // "
                let (end, terminated) = endOfString(ns, from: i)
                add(.string(terminated: terminated), i, end, depth: depth)
                i = end

            case 0x2F where startsRegex(after: tokens.last, text: ns):  // /
                let (end, terminated) = endOfRegex(ns, from: i)
                add(.regex(terminated: terminated), i, end, depth: depth)
                i = end

            case 0x5B:  // [
                add(.openBracket, i, i + 1, depth: depth)
                depth += 1
                i += 1
            case 0x5D:  // ]
                depth = max(0, depth - 1)
                add(.closeBracket, i, i + 1, depth: depth)
                i += 1
            case 0x28: add(.openParen, i, i + 1, depth: depth); i += 1
            case 0x29: add(.closeParen, i, i + 1, depth: depth); i += 1
            case 0x3B: add(.semicolon, i, i + 1, depth: depth); i += 1
            case 0x26, 0x7C: add(.logic, i, i + 1, depth: depth); i += 1

            case 0x3A:  // :
                if unit(i + 1) == 0x3A { add(.doubleColon, i, i + 2, depth: depth); i += 2 } else { add(.colon, i, i + 1, depth: depth); i += 1 }

            case 0x3D:  // =
                if unit(i + 1) == 0x3A, unit(i + 2) != 0x3A { add(.assignment, i, i + 2, depth: depth); i += 2 } else { add(.comparison, i, i + 1, depth: depth); i += 1 }

            case 0x21:  // !
                if unit(i + 1) == 0x3D { add(.comparison, i, i + 2, depth: depth); i += 2 }
                else if depth == 0, let next = unit(i + 1), next == 0x3C || next == 0x3E { add(.arrow, i, i + 2, depth: depth); i += 2 }
                else { add(.negation, i, i + 1, depth: depth); i += 1 }

            case 0x3C, 0x3E:  // < >
                if depth > 0 {
                    if unit(i + 1) == 0x3D { add(.comparison, i, i + 2, depth: depth); i += 2 } else { add(.comparison, i, i + 1, depth: depth); i += 1 }
                } else if c == 0x3C, let end = endOfRegionTag(ns, from: i, afterOperand: endsOperand(tokens.last, text: text)) {
                    add(.regionTag(terminated: end.terminated), i, end.end, depth: depth)
                    i = end.end
                } else if unit(i + 1) == c {
                    add(.arrow, i, i + 2, depth: depth); i += 2
                } else {
                    add(.arrow, i, i + 1, depth: depth); i += 1
                }

            case 0x2A, 0x2B, 0x3F:  // * + ?
                if let last = tokens.last, last.end == i, last.kind == .closeBracket || last.kind == .closeParen {
                    add(.repeatMark, i, i + 1, depth: depth)
                } else {
                    add(.other, i, i + 1, depth: depth)
                }
                i += 1

            case 0x7B:  // {
                if let last = tokens.last, last.end == i, last.kind == .closeBracket || last.kind == .closeParen,
                   let close = endOfRepeatBraces(ns, from: i) {
                    add(.repeatMark, i, close, depth: depth)
                    i = close
                } else {
                    add(.other, i, i + 1, depth: depth)
                    i += 1
                }

            default:
                if isLetterOrDigit(c) || c == 0x5F {
                    var j = i
                    var allDigits = true
                    while j < length, isIdentifierUnit(ns.character(at: j)) {
                        let d = ns.character(at: j)
                        if !(0x30...0x39).contains(d), d != 0x2E { allDigits = false }
                        j += 1
                    }
                    add(allDigits ? .number : .identifier, i, j, depth: depth)
                    i = j
                } else {
                    add(.other, i, i + 1, depth: depth)
                    i += 1
                }
            }
        }
        return tokens
    }

    // MARK: Questions the consumers ask

    /// Whether `token` ends something a binary operator can follow: a token, a value, a name. After one, `<` is an
    /// arrow or a comparison; anywhere else it opens a region tag (`<s>`).
    public static func endsOperand(_ token: CQLToken?, text: String? = nil) -> Bool {
        guard let token else { return false }
        switch token.kind {
        case .closeBracket, .closeParen, .string, .regex, .number, .negation, .arrow, .comparison, .repeatMark: return true
        case .identifier:
            // A scoping word (`within <s>`, `not <s>`) is followed by a region, not by an operator.
            guard let text else { return true }
            let word = (text as NSString).substring(with: token.range)
            return !regionKeywords.contains(word)
        default: return false
        }
    }

    /// The brackets still open after `tokens`.
    public static func openDepth(after tokens: [CQLToken]) -> Int {
        var depth = 0
        for token in tokens {
            if token.kind == .openBracket { depth += 1 } else if token.kind == .closeBracket { depth = max(0, depth - 1) }
        }
        return depth
    }

    // MARK: Scanning

    private static func endOfString(_ ns: NSString, from start: Int) -> (Int, Bool) {
        var i = start + 1
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x5C { i += 2; continue }
            if c == 0x22 { return (i + 1, true) }
            i += 1
        }
        return (ns.length, false)
    }

    /// A `/` opens a regex value only right after `=` or `!=`.
    private static func startsRegex(after last: CQLToken?, text ns: NSString) -> Bool {
        guard let last, last.kind == .comparison else { return false }
        let op = ns.substring(with: last.range)
        return op == "=" || op == "!="
    }

    private static func endOfRegex(_ ns: NSString, from start: Int) -> (Int, Bool) {
        var i = start + 1
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x5C { i += 2; continue }
            if c == 0x2F { return (i + 1, true) }
            i += 1
        }
        return (ns.length, false)
    }

    /// For a `<` that opens a region tag: where the tag ends (after its `>`), or the end of the text when it is still
    /// open. Nil when it is a dependency arrow: a `[`, `:` or `;` comes before any `>`, or what follows is not a name
    /// (`< `, `<<`), or the text ends after something that was an operand (`[] <` is an arrow, `<te` after nothing
    /// is the start of a tag). `</` is always a closing tag.
    private static func endOfRegionTag(_ ns: NSString, from start: Int, afterOperand: Bool) -> (end: Int, terminated: Bool)? {
        var i = start + 1
        guard i < ns.length else { return afterOperand ? nil : (ns.length, false) }
        let first = ns.character(at: i)
        let isLetter = (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first)
        guard isLetter || first == 0x2F else { return nil }
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x22 { i = endOfString(ns, from: i).0; continue }
            if c == 0x5B || c == 0x3A || c == 0x3B || c == 0x3C { return nil }
            if c == 0x3E { return (i + 1, true) }
            i += 1
        }
        return (afterOperand && first != 0x2F) ? nil : (ns.length, false)
    }

    /// `{n}`, `{n,}`, `{n,m}`: the index after the `}`.
    private static func endOfRepeatBraces(_ ns: NSString, from start: Int) -> Int? {
        var i = start + 1
        while i < ns.length {
            let d = ns.character(at: i)
            if d == 0x7D { return i + 1 }
            guard (0x30...0x39).contains(d) || d == 0x2C || d == 0x20 else { return nil }
            i += 1
        }
        return nil
    }
}
