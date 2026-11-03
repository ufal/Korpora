import Foundation

// The seam between the app and a corpus query engine (docs/pando-analysis.md,
// docs/pando-gui-plan.md). The app talks to these protocols; `PandoEngine`
// implements them, tests use fakes, and a remote engine (an FQS server) can be
// added later. The value types the requirements use (`KWICLine`, `CorpusInfo`,
// `SortCriteria`, ...) live in this module too.
//
// Both handles are actors so all access to an engine handle is serialized.

/// An opened corpus.
public protocol CorpusHandle: Actor {
    /// The name this handle was opened with.
    nonisolated var name: String { get }

    /// Token count.
    var size: Int { get async throws }

    func info() async throws -> CorpusInfo

    /// How many distinct values an attribute (`upos`, or a region attribute such as `doc_genre`) has.
    func attributeValueCount(attribute: String) async throws -> Int
    func attributeValues(attribute: String) async throws -> [String]
    func attributeValues(attribute: String, matching pattern: String, ignoreCase: Bool, limit: Int) async throws -> [String]
    /// The most frequent values with their counts (for a region attribute: how many regions have each).
    func topAttributeValues(attribute: String, limit: Int) async throws -> [(value: String, frequency: Int)]
    func topAttributeValues(attribute: String, matching pattern: String, ignoreCase: Bool, limit: Int)
        async throws -> [(value: String, frequency: Int)]
}

extension CorpusHandle {
    public func attributeValues(attribute: String, matching pattern: String) async throws -> [String] {
        try await attributeValues(attribute: attribute, matching: pattern, ignoreCase: true, limit: 0)
    }

    public func topAttributeValues(attribute: String, matching pattern: String, limit: Int)
        async throws -> [(value: String, frequency: Int)] {
        try await topAttributeValues(attribute: attribute, matching: pattern, ignoreCase: true, limit: limit)
    }
}

/// A running query whose loaded hits can be sorted, sampled, grouped and
/// analysed in place.
///
/// Not every hit is loaded: a query with millions of hits loads the first
/// `limit` (see `CorpusEngine.openConcordance`); `size` counts the hits in the
/// current view, `totalHits` all hits in the corpus.
public protocol ConcordanceHandle: Actor {
    /// Number of hits in the current view (loaded, after sampling and group deletion).
    var size: Int { get async }

    /// Number of hits the query has in the corpus, loaded or not.
    var totalHits: Int { get async }

    /// Hits per equal stretch of the corpus, by start position.
    func hitHistogram(bins: Int, corpusSize: Int) async throws -> [Int]

    func sort(_ criteria: SortCriteria, unique: Bool) async throws
    func shuffle() async throws
    /// Keeps `lines` randomly chosen hits of the current view, in their current order.
    func sample(lines: Int) async throws

    /// Line groups: a number assigned to lines (0 = none), for marking hits.
    func setLineGroup(rangeStart: Int, rangeLen: Int, group: Int) async throws
    func linegroup(at lineIndex: Int) async -> Int
    func deleteLineGroups(_ groups: [Int], invert: Bool) async throws

    func kwicLines(leftContext: String, rightContext: String, kwicAttr: String,
                   secondaryAttributes: [String]) async throws -> [KWICLine]

    /// Values of one region attribute (`"doc.title"`) for every line of the current view, in view order.
    func structureValues(attribute: String) async throws -> [String]

    /// Every region attribute of every structure around the hit in view row `row`.
    func structureInfo(forViewRow row: Int) async throws -> [(structure: String, attribute: String, value: String)]

    /// One hit with `tokens` tokens of context each side, as text.
    func extendedContext(forViewRow row: Int, tokens: Int) async throws -> (before: String, match: String, after: String)

    func collocations(_ spec: CollocationSpec) async throws -> [CollocationItem]
    func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int) async throws -> [FrequencyItem]
}

extension ConcordanceHandle {
    public func sort(_ criteria: SortCriteria) async throws { try await sort(criteria, unique: false) }

    public func kwicLines(leftContext: String = "-10", rightContext: String = "10",
                          kwicAttr: String = "form", secondaryAttributes: [String] = []) async throws -> [KWICLine] {
        try await kwicLines(leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr,
                            secondaryAttributes: secondaryAttributes)
    }

    public func frequencyDistribution(_ criteria: [FrequencyCriterion]) async throws -> [FrequencyItem] {
        try await frequencyDistribution(criteria, minFrequency: 1)
    }
}

/// What an engine can do beyond opening corpora and running queries. The app
/// disables the matching controls for an engine that lacks one.
public struct EngineCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let sort = EngineCapabilities(rawValue: 1 << 0)
    public static let shuffle = EngineCapabilities(rawValue: 1 << 1)
    public static let sample = EngineCapabilities(rawValue: 1 << 2)
    public static let lineGroups = EngineCapabilities(rawValue: 1 << 3)
    public static let hitHistogram = EngineCapabilities(rawValue: 1 << 4)
    public static let extendedContext = EngineCapabilities(rawValue: 1 << 5)

    public static let all: EngineCapabilities = [.sort, .shuffle, .sample, .lineGroups, .hitHistogram, .extendedContext]
}

/// An engine: opens corpora and runs queries on them.
public protocol CorpusEngine: Sendable {
    /// Stable identifier stored with saved documents (`"pando"`).
    var id: String { get }

    var capabilities: EngineCapabilities { get }

    func openCorpus(name: String) async throws -> any CorpusHandle

    /// Runs `query` (in the engine's own query language) on `corpus`, which
    /// must have been opened by this engine, and loads up to `limit` hits.
    /// Cancelling the calling task aborts the query and throws `CancellationError`.
    func openConcordance(query: String, in corpus: any CorpusHandle, limit: Int) async throws -> any ConcordanceHandle
}

extension CorpusEngine {
    public var capabilities: EngineCapabilities { .all }

    /// Loads up to `ConcordanceLimit.defaultLimit` hits.
    public func openConcordance(query: String, in corpus: any CorpusHandle) async throws -> any ConcordanceHandle {
        try await openConcordance(query: query, in: corpus, limit: ConcordanceLimit.defaultLimit)
    }
}

public enum ConcordanceLimit {
    /// How many hits a concordance loads when nothing else is asked.
    public static let defaultLimit = 10_000
}

public enum CorpusEngineError: Error, CustomStringConvertible {
    /// A handle from another engine was passed in.
    case foreignHandle(expected: String)

    public var description: String {
        switch self {
        case .foreignHandle(let engine): return "This corpus wasn't opened by the \(engine) engine."
        }
    }
}
