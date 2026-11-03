import Foundation

/// A part of a corpus picked by document properties (genre, year, ...),
/// expressed as a pando region filter that is added to every query run in it
/// (docs/pando-gui-plan.md; KonText's "Text Types" picking).
///
/// Values picked for one attribute are alternatives; different attributes all
/// have to hold: pick two genres and one year and you get hits in documents of
/// either genre from that year. Attribute names are the structure's own
/// (`genre` of structure `doc`); pando names the region attribute `doc_genre`.
public struct SubcorpusRestriction: Codable, Equatable, Sendable {
    public struct Selection: Codable, Equatable, Sendable {
        public var attribute: String
        public var values: [String]

        public init(attribute: String, values: [String]) {
            self.attribute = attribute
            self.values = values
        }
    }

    /// The structure the attributes belong to (`doc`, `text`).
    public var structure: String
    public var selections: [Selection]

    public init(structure: String = "doc", selections: [Selection] = []) {
        self.structure = structure
        self.selections = selections
    }

    /// `match.doc_genre = /fiction|essay/ & match.doc_pubyear = /2007/`: empty when
    /// nothing is selected. Attributes with no values are skipped.
    public var filter: String {
        selections.compactMap { selection -> String? in
            guard !selection.values.isEmpty else { return nil }
            let alternatives = selection.values.map(Self.regexEscaped).joined(separator: "|")
            return "match.\(structure)_\(selection.attribute) = /\(alternatives)/"
        }.joined(separator: " & ")
    }

    public var isEmpty: Bool { filter.isEmpty }

    /// The picks in words: `genre: fiction, essay \u{00B7} year: 2007`.
    public var summary: String {
        selections.filter { !$0.values.isEmpty }
            .map { "\($0.attribute): " + $0.values.map { $0.isEmpty ? "(empty)" : $0 }.joined(separator: ", ") }
            .joined(separator: " \u{00B7} ")
    }

    /// `query` limited to this part of the corpus. An existing `::` filter gets
    /// ` & ...` added, otherwise ` :: ...`.
    public func apply(to query: String) -> String {
        let filter = self.filter
        guard !filter.isEmpty else { return query }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed + (Self.hasGlobalFilter(trimmed) ? " & " : " :: ") + filter
    }

    /// Whether `query` already has a `::` clause (outside quotes, regex literals and brackets).
    static func hasGlobalFilter(_ query: String) -> Bool {
        var quote: Character?
        var previous: Character?
        for character in query {
            if let q = quote {
                if character == q, previous != "\\" { quote = nil }
            } else if character == "\"" || character == "/" {
                quote = character
            } else if character == ":", previous == ":" {
                return true
            }
            previous = character
        }
        return false
    }

    /// `value` with every regular-expression metacharacter escaped, for use
    /// inside a pando `/.../` literal (where `/` ends the literal).
    public static func regexEscaped(_ value: String) -> String {
        var out = ""
        for character in value {
            if #"\.^$*+?()[]{}|/"#.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// The pattern for a "contains" search box over attribute values: `text` matched anywhere.
    public static func containsPattern(_ text: String) -> String {
        ".*" + regexEscaped(text) + ".*"
    }
}

/// A named restriction, saved per corpus.
public struct Subcorpus: Codable, Equatable, Sendable {
    public var name: String
    public var restriction: SubcorpusRestriction

    public init(name: String, restriction: SubcorpusRestriction) {
        self.name = name
        self.restriction = restriction
    }
}

/// The saved subcorpora of every corpus: one small JSON file per corpus, kept in
/// Application Support (not in the corpus folder, which may be read-only or shared).
public enum SubcorpusLibrary {
    /// `KORPORA_SUBCORPORA_DIRECTORY` overrides it (tests).
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["KORPORA_SUBCORPORA_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Korpora/Subcorpora", isDirectory: true)
    }

    private static func file(for corpus: String) -> URL {
        directory.appendingPathComponent(corpus.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    public static func subcorpora(of corpus: String) -> [Subcorpus] {
        guard let data = try? Data(contentsOf: file(for: corpus)),
              let list = try? JSONDecoder().decode([Subcorpus].self, from: data) else { return [] }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves `subcorpus`, replacing one of the same name.
    public static func save(_ subcorpus: Subcorpus, in corpus: String) throws {
        var list = subcorpora(of: corpus).filter { $0.name != subcorpus.name }
        list.append(subcorpus)
        try write(list, for: corpus)
    }

    public static func delete(named name: String, in corpus: String) throws {
        try write(subcorpora(of: corpus).filter { $0.name != name }, for: corpus)
    }

    /// Forgets all subcorpora of a corpus (when the corpus is removed).
    public static func deleteAll(of corpus: String) {
        try? FileManager.default.removeItem(at: file(for: corpus))
    }

    private static func write(_ list: [Subcorpus], for corpus: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: file(for: corpus), options: .atomic)
    }
}
