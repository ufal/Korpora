import Foundation

/// pando as a `CorpusEngine` (docs/pando-gui-plan.md).
///
/// A corpus is an index folder found by name in the `CorpusLibrary` (or given
/// as an absolute path). A query loads up to a limit of hits; sorting,
/// sampling, shuffling and line groups work on those (`PandoConcordance`).
public struct PandoEngine: CorpusEngine {
    public let library: PandoLibrary
    private let resolve: @Sendable (String) -> String?

    /// Corpora are found in the app's `CorpusLibrary` by name (or by absolute path).
    public init(library: PandoLibrary) {
        self.library = library
        resolve = { name in name.hasPrefix("/") ? name : CorpusLibrary.directory(forName: name)?.path }
    }

    /// Corpora are folders under `corporaRoot` (tests, tools).
    public init(library: PandoLibrary, corporaRoot: URL) {
        self.library = library
        resolve = { name in name.hasPrefix("/") ? name : corporaRoot.appendingPathComponent(name).path }
    }

    public var id: String { "pando" }

    public var capabilities: EngineCapabilities { .all }

    func directory(for name: String) throws -> String {
        guard let path = resolve(name) else {
            throw PandoError.failure("There is no corpus named \u{201C}\(name)\u{201D}.")
        }
        return path
    }

    public func openCorpus(name: String) async throws -> any CorpusHandle {
        try PandoCorpus(library: library, name: name, directory: directory(for: name))
    }

    public func openConcordance(query: String, in corpus: any CorpusHandle, limit: Int) async throws -> any ConcordanceHandle {
        guard let corpus = corpus as? PandoCorpus else { throw CorpusEngineError.foreignHandle(expected: id) }
        return try await PandoConcordance(corpus: corpus, query: query, limit: limit)
    }
}

enum PandoNames {
    /// pando names a region attribute `structure_attribute`; the app writes `structure.attribute`.
    static func attribute(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }
}

/// An opened pando index. Reads that must not share a thread with another
/// handle use their own engine handle (an open handle holds no file descriptors).
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
                          attributes: attributes, structures: StructureInfo.ordered(structures))
    }

    // MARK: Attribute values (`show values`)

    private func values(_ attribute: String, limit: Int) throws -> (unique: Int, rows: [(value: String, frequency: Int)]) {
        let object = try library.result(library.run(
            handle, "show values \(PandoNames.attribute(attribute))", PandoLibrary.json(["limit": limit])))
        let rows = (object["values"] as? [[String: Any]] ?? []).compactMap { row -> (String, Int)? in
            guard let value = row["value"] as? String, let count = row["count"] as? Int else { return nil }
            return (value, count)
        }
        return (object["unique"] as? Int ?? rows.count, rows)
    }

    public func attributeValueCount(attribute: String) throws -> Int {
        try values(attribute, limit: 1).unique
    }

    public func attributeValues(attribute: String) throws -> [String] {
        try values(attribute, limit: Int.max / 2).rows.map(\.value).sorted()
    }

    private static func matcher(_ pattern: String, ignoreCase: Bool) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: "^(?:\(pattern))$", options: ignoreCase ? [.caseInsensitive] : [])
    }

    public func attributeValues(attribute: String, matching pattern: String, ignoreCase: Bool, limit: Int) throws -> [String] {
        let regex = try Self.matcher(pattern, ignoreCase: ignoreCase)
        let hits = try attributeValues(attribute: attribute).filter {
            regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
        return limit > 0 ? Array(hits.prefix(limit)) : hits
    }

    public func topAttributeValues(attribute: String, limit: Int) throws -> [(value: String, frequency: Int)] {
        Array(try values(attribute, limit: limit).rows.prefix(limit))
    }

    public func topAttributeValues(attribute: String, matching pattern: String, ignoreCase: Bool, limit: Int)
        throws -> [(value: String, frequency: Int)] {
        let regex = try Self.matcher(pattern, ignoreCase: ignoreCase)
        let hits = try values(attribute, limit: Int.max / 2).rows.filter {
            regex.firstMatch(in: $0.value, range: NSRange($0.value.startIndex..., in: $0.value)) != nil
        }
        return Array(hits.prefix(limit))
    }
}
