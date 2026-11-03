import CorpusEngine
import Foundation

/// pando as a `CorpusEngine` (docs/pando-analysis.md, Phase C spike).
///
/// A corpus is an index directory: `name` is a folder under `corporaRoot`, or
/// an absolute path. What pando has no equivalent for (sort, filter, line
/// groups, subcorpora, ...) isn't in `capabilities` and throws
/// `PandoError.unsupported` if called anyway.
public struct PandoEngine: CorpusEngine {
    public let library: PandoLibrary
    public let corporaRoot: URL

    public init(library: PandoLibrary, corporaRoot: URL) {
        self.library = library
        self.corporaRoot = corporaRoot
    }

    public var id: String { "pando" }

    public var capabilities: EngineCapabilities { [] }

    func directory(for name: String) -> String {
        name.hasPrefix("/") ? name : corporaRoot.appendingPathComponent(name).path
    }

    public func openCorpus(name: String) async throws -> any CorpusHandle {
        try PandoCorpus(library: library, name: name, directory: directory(for: name))
    }

    public func openConcordance(query: String, in corpus: any CorpusHandle) async throws -> any ConcordanceHandle {
        guard let corpus = corpus as? PandoCorpus else { throw CorpusEngineError.foreignHandle(expected: id) }
        return try await PandoConcordance(corpus: corpus, query: query)
    }
}

/// An opened pando index. Everything but `info`-like reads opens its own
/// engine handle, because one handle isn't for use from two threads at once.
public actor PandoCorpus: CorpusHandle {
    public nonisolated let name: String
    nonisolated let library: PandoLibrary
    nonisolated let directory: String
    nonisolated(unsafe) private let handle: OpaquePointer

    init(library: PandoLibrary, name: String, directory: String) throws {
        self.library = library
        self.name = name
        self.directory = directory
        handle = try library.openHandle(directory: directory)
    }

    deinit { library.close(handle) }

    private func infoObject() throws -> [String: Any] {
        try library.result(library.info(handle))
    }

    public var size: Int {
        get throws { (try infoObject()["size"] as? Int) ?? 0 }
    }

    public func info() throws -> CorpusInfo {
        let object = try infoObject()
        let attributes = (object["attributes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let structures = (object["structures"] as? [[String: Any]] ?? []).compactMap { entry -> StructureInfo? in
            guard let name = entry["name"] as? String else { return nil }
            return StructureInfo(name: name, attributes: entry["attrs"] as? [String] ?? [])
        }
        return CorpusInfo(name: name, sizeTokens: object["size"] as? Int ?? 0,
                          attributes: attributes, structures: structures)
    }

    // MARK: Attribute values (`show values`)

    private func values(_ attribute: String, limit: Int) throws -> (unique: Int, rows: [(value: String, frequency: Int)]) {
        let object = try library.result(library.run(
            handle, "show values \(Self.pandoAttribute(attribute))", PandoLibrary.json(["limit": limit])))
        let rows = (object["values"] as? [[String: Any]] ?? []).compactMap { row -> (String, Int)? in
            guard let value = row["value"] as? String, let count = row["count"] as? Int else { return nil }
            return (value, count)
        }
        return (object["unique"] as? Int ?? rows.count, rows)
    }

    /// Manatee corpora say `word`; pando's token text attribute is `form`.
    static func pandoAttribute(_ attribute: String) -> String { attribute == "word" ? "form" : attribute }

    public func attributeValueCount(attribute: String) throws -> Int {
        try values(attribute, limit: 1).unique
    }

    public func attributeValues(attribute: String) throws -> [String] {
        try values(attribute, limit: Int.max / 2).rows.map(\.value).sorted()
    }

    public func attributeValues(attribute: String, matching pattern: String, ignoreCase: Bool, limit: Int) throws -> [String] {
        let all = try attributeValues(attribute: attribute)
        let regex = try NSRegularExpression(pattern: "^(?:\(pattern))$", options: ignoreCase ? [.caseInsensitive] : [])
        let hits = all.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        return limit > 0 ? Array(hits.prefix(limit)) : hits
    }

    public func topAttributeValues(attribute: String, limit: Int) throws -> [(value: String, frequency: Int)] {
        Array(try values(attribute, limit: limit).rows.prefix(limit))
    }

    public func topAttributeValues(attribute: String, matching pattern: String, ignoreCase: Bool, limit: Int)
        throws -> [(value: String, frequency: Int)] {
        let regex = try NSRegularExpression(pattern: "^(?:\(pattern))$", options: ignoreCase ? [.caseInsensitive] : [])
        let hits = try values(attribute, limit: Int.max / 2).rows.filter {
            regex.firstMatch(in: $0.value, range: NSRange($0.value.startIndex..., in: $0.value)) != nil
        }
        return Array(hits.prefix(limit))
    }

    // MARK: Not available

    public func createSubcorpus(named subcorpusName: String, structure: String, query: String) throws -> String {
        throw PandoError.unsupported("Subcorpora")
    }

    public func structuralAttributeValue(at position: Int, attribute: String) throws -> String {
        throw PandoError.unsupported("Looking up a structure attribute at a position")
    }

    public func positionalAttributeRange(from fromPosition: Int, to toPosition: Int, attribute: String) throws -> String {
        throw PandoError.unsupported("Extended context")
    }

    public func openSubcorpusHandle(atPath path: String) throws -> any CorpusHandle {
        throw PandoError.unsupported("Subcorpora")
    }
}
