import Foundation

// The seam between the app and a corpus query engine (docs/pando-analysis.md,
// Phase B). The app talks to these protocols; `ManateeKit` implements them for
// Manatee, and a second engine can implement them later. The value types the
// requirements use (`KWICLine`, `CorpusInfo`, `SortCriteria`, ...) are
// engine-neutral and live in this module too.
//
// Both handles are actors because engines aren't thread-safe on one handle,
// so all access is serialized through them.

/// An opened corpus (or a subcorpus of one).
public protocol CorpusHandle: Actor {
    /// The name (or subcorpus path) this handle was opened with.
    nonisolated var name: String { get }

    /// Token count; for a subcorpus, its own restricted size.
    var size: Int { get async throws }

    func info() async throws -> CorpusInfo

    /// Creates a subcorpus of `structure` instances matching `query` and returns
    /// where it was stored.
    func createSubcorpus(named subcorpusName: String, structure: String, query: String) async throws -> String

    /// The value of structural attribute `attribute` (`"doc.author"`) enclosing `position`.
    func structuralAttributeValue(at position: Int, attribute: String) async throws -> String

    /// Space-joined values of a positional attribute over `[fromPosition, toPosition)`.
    func positionalAttributeRange(from fromPosition: Int, to toPosition: Int, attribute: String) async throws -> String

    func attributeValueCount(attribute: String) async throws -> Int
    func attributeValues(attribute: String) async throws -> [String]
    func attributeValues(attribute: String, matching pattern: String, ignoreCase: Bool, limit: Int) async throws -> [String]
    func topAttributeValues(attribute: String, limit: Int) async throws -> [(value: String, frequency: Int)]
    func topAttributeValues(attribute: String, matching pattern: String, ignoreCase: Bool, limit: Int)
        async throws -> [(value: String, frequency: Int)]

    /// Opens a subcorpus stored at `path` (as returned by `createSubcorpus`).
    func openSubcorpusHandle(atPath path: String) async throws -> any CorpusHandle
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

/// A running query whose result set can be sorted, filtered, sampled and
/// analysed in place.
public protocol ConcordanceHandle: Actor {
    /// Number of hits in the current view.
    var size: Int { get async }

    /// Hits per equal stretch of the corpus, by start position.
    func hitHistogram(bins: Int, corpusSize: Int) async throws -> [Int]

    func sort(_ criteria: SortCriteria, unique: Bool) async throws
    func shuffle() async throws
    func sample(lines: Int) async throws
    func filter(_ spec: PNFilterSpec) async throws

    func setLineGroup(rangeStart: Int, rangeLen: Int, group: Int) async throws
    func linegroup(at lineIndex: Int) async -> Int
    func deleteLineGroups(_ groups: [Int], invert: Bool) async throws

    func kwicLines(leftContext: String, rightContext: String, kwicAttr: String,
                   secondaryAttributes: [String]) async throws -> [KWICLine]

    func collocations(_ spec: CollocationSpec) async throws -> [CollocationItem]
    func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int) async throws -> [FrequencyItem]
}

extension ConcordanceHandle {
    public func sort(_ criteria: SortCriteria) async throws { try await sort(criteria, unique: false) }

    public func kwicLines(leftContext: String = "-10", rightContext: String = "10",
                          kwicAttr: String = "word", secondaryAttributes: [String] = []) async throws -> [KWICLine] {
        try await kwicLines(leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr,
                            secondaryAttributes: secondaryAttributes)
    }

    public func frequencyDistribution(_ criteria: [FrequencyCriterion]) async throws -> [FrequencyItem] {
        try await frequencyDistribution(criteria, minFrequency: 1)
    }
}

/// An engine: opens corpora and runs queries on them.
public protocol CorpusEngine: Sendable {
    /// Stable identifier stored with saved documents (`"manatee"`).
    var id: String { get }

    func openCorpus(name: String) async throws -> any CorpusHandle

    /// Runs `query` (in the engine's own query language) on `corpus`, which
    /// must have been opened by this engine. Cancelling the calling task
    /// aborts the query and throws `CancellationError`.
    func openConcordance(query: String, in corpus: any CorpusHandle) async throws -> any ConcordanceHandle
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
