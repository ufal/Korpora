import CorpusEngine

/// The Manatee implementation of `CorpusEngine`.
public struct ManateeEngine: CorpusEngine {
    public init() {}

    public var id: String { "manatee" }

    public func openCorpus(name: String) async throws -> any CorpusHandle {
        try Corpus(name: name)
    }

    public func openConcordance(query: String, in corpus: any CorpusHandle) async throws -> any ConcordanceHandle {
        guard let corpus = corpus as? Corpus else { throw CorpusEngineError.foreignHandle(expected: id) }
        return try await LiveConcordance(corpus: corpus, cql: query)
    }
}
