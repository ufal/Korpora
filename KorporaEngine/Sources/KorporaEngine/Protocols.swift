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

/// A running query whose hits can be read a window at a time, and sorted,
/// sampled, grouped and analysed in place.
///
/// Lines are read from the engine a window at a time, so a result of any size
/// can be scrolled. Sorting by one key, shuffling and sampling of a big result
/// are done by the engine too, on all its hits. Anything else (several sort
/// keys, line groups, ...) needs the hits in memory: it works on the first
/// `limit` hits (see `CorpusEngine.openConcordance`) and the view shrinks to
/// those (`viewIsPartial`). `size` counts the hits in the current view,
/// `totalHits` all hits in the corpus.
public protocol ConcordanceHandle: Actor {
    /// Number of hits in the current view (all hits until an operation; then the loaded ones,
    /// after sampling and group deletion).
    var size: Int { get async }

    /// Number of hits the query has in the corpus, loaded or not.
    var totalHits: Int { get async }

    /// An operation could only work on the first hits of a result too big to hold in memory, so the
    /// view is shorter than what the operations asked for.
    var viewIsPartial: Bool { get async }

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

    /// The lines of the view rows in `range` (clamped to the view), in view order.
    func kwicLines(range: Range<Int>, leftContext: String, rightContext: String, kwicAttr: String,
                   secondaryAttributes: [String]) async throws -> [KWICLine]

    /// Values of one region attribute (`"doc.title"`) for the view rows in `range`, in view order.
    func structureValues(attribute: String, range: Range<Int>) async throws -> [String]

    /// How many lines of the view are in each line group (groups without lines are left out).
    func lineGroupCounts() async -> [Int: Int]

    /// Every region attribute of every structure around the hit in view row `row`.
    func structureInfo(forViewRow row: Int) async throws -> [(structure: String, attribute: String, value: String)]

    /// One hit with `tokens` tokens of context each side, as text.
    func extendedContext(forViewRow row: Int, tokens: Int) async throws -> (before: String, match: String, after: String)

    func collocations(_ spec: CollocationSpec) async throws -> [CollocationItem]
    func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int) async throws -> [FrequencyItem]

    /// A frequency over attributes of the query's nodes (and text or document properties), one column for each
    /// field (docs/frequency-composer.md). Throws `FrequencyError` for a node the query doesn't have.
    func frequencyTable(_ fields: [FrequencyField], minFrequency: Int) async throws -> FrequencyTable
}

extension ConcordanceHandle {
    public func sort(_ criteria: SortCriteria) async throws { try await sort(criteria, unique: false) }

    /// Every line of the view (for a result of millions of hits, ask for ranges instead).
    public func kwicLines(leftContext: String = "-10", rightContext: String = "10",
                          kwicAttr: String = "form", secondaryAttributes: [String] = []) async throws -> [KWICLine] {
        let count = await size
        return try await kwicLines(range: 0..<count, leftContext: leftContext, rightContext: rightContext,
                            kwicAttr: kwicAttr, secondaryAttributes: secondaryAttributes)
    }

    /// The region attribute for every line of the view.
    public func structureValues(attribute: String) async throws -> [String] {
        let count = await size
        return try await structureValues(attribute: attribute, range: 0..<count)
    }

    public var viewIsPartial: Bool { get async { false } }

    public func lineGroupCounts() async -> [Int: Int] { [:] }

    public func frequencyDistribution(_ criteria: [FrequencyCriterion]) async throws -> [FrequencyItem] {
        try await frequencyDistribution(criteria, minFrequency: 1)
    }

    public func frequencyTable(_ fields: [FrequencyField]) async throws -> FrequencyTable {
        try await frequencyTable(fields, minFrequency: 1)
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
    /// must have been opened by this engine. `limit` is how many hits an operation
    /// (sort, shuffle, sample, line groups) can work on; reading lines needs no limit.
    /// Cancelling the calling task aborts the query and throws `CancellationError`.
    func openConcordance(query: String, in corpus: any CorpusHandle, limit: Int) async throws -> any ConcordanceHandle
}

extension CorpusEngine {
    public var capabilities: EngineCapabilities { .all }

    /// With `ConcordanceLimit.defaultLimit` as the limit for operations.
    public func openConcordance(query: String, in corpus: any CorpusHandle) async throws -> any ConcordanceHandle {
        try await openConcordance(query: query, in: corpus, limit: ConcordanceLimit.defaultLimit)
    }
}

public enum ConcordanceLimit {
    /// How many hits an operation (sort, shuffle, sample, line groups) works on when nothing else
    /// is asked. A result with more hits can still be read to its end, but is sorted only over its
    /// first hits: pando can't yet sort a result of that size through its C API
    /// (docs/pando-gui-plan.md, "Paging long results").
    public static let defaultLimit = 100_000
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
