import Foundation

// Both of these carry `public let`s but had only their synthesized
// *internal* initializers, so a client could read one but never build one -
// which also meant a client couldn't unit-test anything taking a
// `CorpusInfo` without opening a real corpus. They're plain value types
// describing a schema, so being constructible is the intended shape.

public struct StructureInfo: Sendable {
    public let name: String
    public let attributes: [String]

    public init(name: String, attributes: [String]) {
        self.name = name
        self.attributes = attributes
    }
}

extension StructureInfo {
    /// A UD sentence translation, `# text_en = ...`, which pando keeps as the attribute `text_en` of `s`: 2 or 3
    /// letters after `text_`, the way pando's own reader tells them from other `text_` keys. There can be dozens.
    static func isSentenceTranslation(_ attribute: String) -> Bool {
        guard attribute.hasPrefix("text_") else { return false }
        let code = attribute.dropFirst(5)
        let notLanguages: Set<Substring> = ["id", "src", "ref", "dom", "uri", "url", "num", "cat", "new", "old"]
        return (2...3).contains(code.count) && code.allSatisfy { $0 >= "a" && $0 <= "z" } && !notLanguages.contains(code)
    }

    /// The structures of a corpus in a useful order, and each one's attributes in natural alphabetical order
    /// (pando lists them as it stored them: a corpus such as UD has over a hundred, in no order). The text and the
    /// document come first, then the paragraph and the sentence, the rest alphabetically; in the sentence the
    /// translations (`text_en`, `text_cs`, ...) go after everything else.
    static func ordered(_ structures: [StructureInfo]) -> [StructureInfo] {
        let known = ["text", "doc", "p", "par", "s"]
        func natural(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        let sorted = structures.map { structure -> StructureInfo in
            let own = structure.attributes.filter { !(structure.name == "s" && isSentenceTranslation($0)) }
            let translations = structure.attributes.filter { structure.name == "s" && isSentenceTranslation($0) }
            return StructureInfo(name: structure.name, attributes: own.sorted(by: natural) + translations.sorted(by: natural))
        }
        return sorted.sorted { a, b in
            switch (known.firstIndex(of: a.name), known.firstIndex(of: b.name)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return natural(a.name, b.name)
            }
        }
    }
}

public struct CorpusInfo: Sendable {
    public let name: String
    public let sizeTokens: Int
    public let attributes: [String]
    public let structures: [StructureInfo]

    public init(name: String, sizeTokens: Int, attributes: [String], structures: [StructureInfo]) {
        self.name = name
        self.sizeTokens = sizeTokens
        self.attributes = attributes
        self.structures = structures
    }
}

extension CorpusInfo {
    /// The attribute that holds a token's text: `form` for pando corpora
    /// (CoNLL-U), `word` for older ones, else the first attribute.
    public var defaultAttribute: String {
        for candidate in ["form", "word"] where attributes.contains(candidate) { return candidate }
        return attributes.first ?? "form"
    }
}
