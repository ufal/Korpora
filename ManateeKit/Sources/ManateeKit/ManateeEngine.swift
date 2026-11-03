import CorpusEngine

/// The Manatee implementation of `CorpusEngine`.
public struct ManateeEngine: CorpusEngine {
    public init() {}

    public var id: String { "manatee" }

    public func openCorpus(name: String) async throws -> any CorpusHandle {
        try await OpenGate.shared.open(name: name)
    }

    public func openConcordance(query: String, in corpus: any CorpusHandle) async throws -> any ConcordanceHandle {
        guard let corpus = corpus as? Corpus else { throw CorpusEngineError.foreignHandle(expected: id) }
        return try await LiveConcordance(corpus: corpus, cql: query)
    }
}

/// Manatee isn't thread-safe: opening corpora from two threads at once
/// corrupted its heap (a crash in `Corpus::~Corpus`, seen in tests after the
/// engine seam made `openCorpus` async and so ran it on the cooperative pool;
/// before, every open happened on the main thread). All opens go through this
/// one actor so they never overlap.
actor OpenGate {
    static let shared = OpenGate()

    func open(name: String) throws -> Corpus {
        try Corpus(name: name)
    }
}
