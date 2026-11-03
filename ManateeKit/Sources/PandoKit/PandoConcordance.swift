import CorpusEngine
import Foundation

/// A pando query. pando evaluates lazily and pages, so this keeps the query
/// text and its total, and fetches KWIC lines on demand; collocations and
/// frequencies run as programs (`QUERY; coll by lemma`).
///
/// Owns its own engine handle (cheap: an open handle holds no file
/// descriptors), so it can be cancelled from another thread and never shares
/// a handle between threads.
public actor PandoConcordance: ConcordanceHandle {
    private let library: PandoLibrary
    nonisolated(unsafe) private let handle: OpaquePointer
    private var query: String
    private var total: Int

    init(corpus: PandoCorpus, query: String) async throws {
        let library = corpus.library
        self.library = library
        let handle = try library.openHandle(directory: corpus.directory)
        self.handle = handle
        self.query = query
        // The count blocks its thread; only the cancel handler, which runs on
        // whichever thread cancels the task, can reach it while it does.
        // (pando drops a cancel that arrives before the call starts, hence
        // the check afterwards.)
        let counted: Int = try await withTaskCancellationHandler {
            let object = try library.result(library.query(
                handle, query, PandoLibrary.json(["limit": 1, "total": true])))
            let page = object["page"] as? [String: Any]
            return page?["total"] as? Int ?? 0
        } onCancel: {
            library.cancel(handle)
        }
        try Task.checkCancellation()
        total = counted
    }

    deinit { library.close(handle) }

    public var size: Int { total }

    // MARK: Lines

    /// "-10" / "10" (Bonito's token counts) as a count; anything else
    /// (structure contexts such as "-1:s") falls back to 10.
    private static func tokens(in context: String) -> Int {
        Int(context).map { abs($0) } ?? 10
    }

    public func kwicLines(leftContext: String, rightContext: String, kwicAttr: String,
                          secondaryAttributes: [String]) throws -> [KWICLine] {
        let wanted = size
        guard wanted > 0 else { return [] }
        let attributes = ([kwicAttr] + secondaryAttributes).map(PandoCorpus.pandoAttribute)
        let object = try library.result(library.query(handle, query, PandoLibrary.json([
            "limit": wanted, "offset": 0, "total": false,
            "context": max(Self.tokens(in: leftContext), Self.tokens(in: rightContext)),
            "attrs": attributes,
        ])))
        return (object["hits"] as? [[String: Any]] ?? []).map { hit in
            func words(_ text: String?) -> [KWICToken] {
                (text ?? "").split(separator: " ").map { KWICToken(word: String($0), secondaryAttributes: [:]) }
            }
            let context = hit["context"] as? [String: Any]
            let matchTokens = (hit["tokens"] as? [[String: Any]] ?? []).map { token -> KWICToken in
                var secondary: [String: String] = [:]
                for (index, name) in secondaryAttributes.enumerated() {
                    if let value = token[attributes[index + 1]] as? String { secondary[name] = value }
                }
                return KWICToken(word: token[attributes[0]] as? String ?? "", secondaryAttributes: secondary)
            }
            return KWICLine(
                leftTokens: words(context?["left"] as? String),
                kwicTokens: matchTokens.isEmpty ? words(context?["match"] as? String) : matchTokens,
                rightTokens: words(context?["right"] as? String),
                position: hit["match_start"] as? Int ?? 0)
        }
    }

    // MARK: Analyses

    private static func measureName(_ measure: AssociationMeasure) -> String {
        switch measure {
        case .logDice: return "logdice"
        case .mutualInformation: return "mi"
        case .mi3: return "mi3"
        case .tScore: return "tscore"
        case .logLikelihood: return "ll"
        case .dice: return "dice"
        }
    }

    public func collocations(_ spec: CollocationSpec) throws -> [CollocationItem] {
        let measure = Self.measureName(spec.measure)
        let object = try library.result(library.run(
            handle, "\(query); coll by \(PandoCorpus.pandoAttribute(spec.attribute))", PandoLibrary.json([
                "coll_left": abs(spec.leftWindow), "coll_right": abs(spec.rightWindow),
                "coll_min_freq": spec.minCollocateFrequency, "coll_max_items": spec.maxItems,
                "measures": [measure],
            ])))
        return (object["collocates"] as? [[String: Any]] ?? []).compactMap { row in
            guard let word = row["word"] as? String else { return nil }
            let score = (row[measure] as? Double) ?? Double(row[measure] as? Int ?? 0)
            return CollocationItem(word: word, freq: row["freq"] as? Int ?? 0, cnt: row["obs"] as? Int ?? 0, score: score)
        }
    }

    public func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int) throws -> [FrequencyItem] {
        guard !criteria.isEmpty else { return [] }
        if criteria.contains(where: { $0.contextOffset != 0 }) {
            throw PandoError.unsupported("Frequencies at a context offset")
        }
        let fields = criteria.map { PandoCorpus.pandoAttribute($0.attribute) }.joined(separator: ", ")
        let object = try library.result(library.run(
            handle, "\(query); count by \(fields)", PandoLibrary.json(["limit": 100_000])))
        return (object["rows"] as? [[String: Any]] ?? []).compactMap { row in
            guard let key = row["key"] as? String, let count = row["count"] as? Int, count >= minFrequency else { return nil }
            return FrequencyItem(word: key, freq: count)
        }
    }

    // MARK: Operations

    public func sample(lines: Int) throws { throw PandoError.unsupported("Sampling") }

    public func hitHistogram(bins: Int, corpusSize: Int) throws -> [Int] {
        throw PandoError.unsupported("The dispersion plot")
    }

    public func sort(_ criteria: SortCriteria, unique: Bool) throws { throw PandoError.unsupported("Sorting") }
    public func shuffle() throws { throw PandoError.unsupported("Shuffling") }
    public func filter(_ spec: PNFilterSpec) throws { throw PandoError.unsupported("Filtering") }
    public func setLineGroup(rangeStart: Int, rangeLen: Int, group: Int) throws { throw PandoError.unsupported("Line groups") }
    public func linegroup(at lineIndex: Int) -> Int { 0 }
    public func deleteLineGroups(_ groups: [Int], invert: Bool) throws { throw PandoError.unsupported("Line groups") }
}
