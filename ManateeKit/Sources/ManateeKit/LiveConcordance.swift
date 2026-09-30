import CManatee
import CorpusEngine

/// A single Manatee corpus query, kept open and mutable so sort/shuffle/
/// sample/filter/line-group operations can compose on one running result
/// set - the gap the old open-query-then-discard `Corpus.query` API left.
/// A flag that aborts a running query from any thread (see
/// `LiveConcordance.init(corpus:cql:)`, which raises it when its task is
/// cancelled).
final class QueryCancellationToken: @unchecked Sendable {
    let handle: OpaquePointer

    init() { handle = mtc_cancel_token_new()! }
    deinit { mtc_cancel_token_free(handle) }

    func cancel() { mtc_cancel_token_cancel(handle) }
    var isCancelled: Bool { mtc_cancel_token_is_cancelled(handle) != 0 }
}

/// An actor for the same reason `Corpus` is one: Manatee's thread-safety
/// under concurrent access to one handle is undocumented.
public actor LiveConcordance: ConcordanceHandle {
    // Keeps the parent corpus alive for as long as this concordance exists -
    // `corpusHandle` is only a raw pointer, so without this a caller that
    // drops its last reference to `Corpus` would have it deinit (closing
    // the underlying handle via `mtc_corpus_close`) out from under a still-
    // live concordance, a use-after-free `mtc_kwic_open` would only sometimes
    // visibly misbehave on.
    private let corpus: Corpus
    private let corpusHandle: OpaquePointer
    private let handle: OpaquePointer

    /// Collocation slot 1 is reserved for filter operations - Manatee numbers
    /// these per-concordance, not per-filter-call, but this wrapper only
    /// ever needs one active at a time (`filter` fully replaces slot 1 each
    /// call rather than layering).
    private static let filterCollocationSlot: Int32 = 1

    /// Runs `cql` and waits for the whole result.
    ///
    /// Cancelling the calling task aborts the query in the engine (its
    /// worker thread is cancelled and joined) and this throws
    /// `CancellationError`. Latency is about 10 ms plus the time to the
    /// engine's next hit: a query that's still being parsed (regular
    /// expressions are expanded over the lexicon first) or is searching a
    /// long stretch without a hit notices the cancel only afterwards.
    public init(corpus: Corpus, cql: String) async throws {
        self.corpus = corpus
        let corpusHandle = corpus.handle
        self.corpusHandle = corpusHandle
        let token = QueryCancellationToken()
        // The query blocks its thread; only the cancel handler, which runs on
        // whichever thread cancels the task, can reach it while it does.
        handle = try await withTaskCancellationHandler {
            try Self.runQuery(corpusHandle, cql: cql, token: token)
        } onCancel: {
            token.cancel()
        }
    }

    private static func runQuery(
        _ corpusHandle: OpaquePointer, cql: String, token: QueryCancellationToken
    ) throws -> OpaquePointer {
        var error: UnsafeMutablePointer<CChar>?
        guard let h = mtc_query_cancellable(corpusHandle, cql, token.handle, &error) else {
            let message = consumeError(error)
            if token.isCancelled { throw CancellationError() }
            throw ManateeError.failure(message)
        }
        return h
    }

    deinit {
        mtc_concordance_close(handle)
    }

    public var size: Int {
        Int(mtc_concordance_size(handle))
    }

    /// How many of the current view's hits (after any sample, filter or
    /// removed line) start in each of `bins` equal stretches of a corpus of
    /// `corpusSize` tokens: the data of a dispersion plot. `corpusSize` is
    /// the size of the corpus the hits' positions are numbered in, which for
    /// a subcorpus is the parent corpus's, not the subcorpus's own.
    public func hitHistogram(bins: Int, corpusSize: Int) throws -> [Int] {
        var counts = [Int64](repeating: 0, count: max(bins, 1))
        var error: UnsafeMutablePointer<CChar>?
        let total = counts.withUnsafeMutableBufferPointer {
            mtc_concordance_hit_histogram(handle, Int64(corpusSize), Int32(bins), $0.baseAddress, &error)
        }
        guard total >= 0 else {
            throw ManateeError.failure(consumeError(error))
        }
        return counts.map(Int.init)
    }

    public func sort(_ criteria: SortCriteria, unique: Bool = false) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_concordance_sort(handle, criteria.criteriaString, unique ? 1 : 0, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func shuffle() throws {
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_concordance_shuffle(handle, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    /// Reduces to (approximately) `lines` lines. Resets any prior sort/
    /// shuffle order - see `mtc_concordance_reduce`'s doc comment; that's
    /// Manatee's own behavior, not a limitation of this wrapper.
    public func sample(lines: Int) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_concordance_reduce(handle, Int64(lines), &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func filter(_ spec: PNFilterSpec) throws {
        var error: UnsafeMutablePointer<CChar>?
        let collnum = Self.filterCollocationSlot
        guard mtc_concordance_set_collocation(
            handle, collnum, spec.query, String(spec.leftOffset), String(spec.rightOffset),
            spec.rank.rank, spec.includeKwic ? 0 : 1, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
        guard mtc_concordance_pnfilter(handle, collnum, spec.positive ? 1 : 0, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func setLineGroup(rangeStart: Int, rangeLen: Int, group: Int) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard mtc_concordance_set_linegroup(
            handle, Int64(rangeStart), Int64(rangeLen), Int32(group), &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    public func linegroup(at lineIndex: Int) -> Int {
        Int(mtc_concordance_get_linegroup(handle, Int64(lineIndex)))
    }

    /// Keeps only lines in the given groups, discarding the rest - used to
    /// implement "clear line groups" isn't this; the document layer clears
    /// grouping by dropping line-group operations from its chain and
    /// replaying, since Manatee has no "reset all labels but keep every
    /// line" call of its own (`delete_linegroups` only ever removes lines).
    public func deleteLineGroups(_ groups: [Int], invert: Bool) throws {
        var error: UnsafeMutablePointer<CChar>?
        let spec = groups.map(String.init).joined(separator: " ")
        guard mtc_concordance_delete_linegroups(handle, spec, invert ? 1 : 0, &error) != 0 else {
            throw ManateeError.failure(consumeError(error))
        }
    }

    /// `secondaryAttributes` (e.g. `["lemma", "tag"]`) are read alongside
    /// `kwicAttr` per token, for a caller wanting to show more than one
    /// attribute per word (KonText-style) - see `KWICToken`. Fetching N
    /// secondary attributes costs 3N extra bridge calls per line (one per
    /// left/kwic/right segment per attribute) on top of the 3 already made
    /// for `kwicAttr` itself - fine for the handful of attributes a picker
    /// UI realistically requests, but something to keep in mind against an
    /// already-large, unpaginated result set (`kwicLines` fetches every
    /// hit's line up front, regardless of how many are ever shown).
    ///
    /// Fetches *every* hit (there is no paging yet, Phase 6.11), which for a
    /// common word in a big corpus is millions of lines: the calling task's
    /// cancellation is checked here as it goes (and throws `CancellationError`),
    /// or a cancelled search would sit in this loop until the last line.
    public func kwicLines(leftContext: String = "-10", rightContext: String = "10",
                           kwicAttr: String = "word", secondaryAttributes: [String] = []) throws -> [KWICLine] {
        try Task.checkCancellation()
        var error: UnsafeMutablePointer<CChar>?
        guard let kwic = mtc_kwic_open(corpusHandle, handle, leftContext, rightContext, kwicAttr, &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_kwic_close(kwic) }

        // Nested functions (not `Self.`-scoped helpers) so both capture
        // `error` by reference - `decode` must see whatever `error` a
        // `fetch` call just set, at the moment it actually failed, not a
        // value snapshotted before that call ran.
        func decode(_ cString: UnsafeMutablePointer<CChar>?) throws -> [String] {
            guard let cString else {
                throw ManateeError.failure(consumeError(error))
            }
            defer { mtc_free_string(cString) }
            let joined = String(cString: cString)
            guard !joined.isEmpty else { return [] }
            // Leading-delimiter encoding - see mtcbridge.h's doc comment on
            // mtc_kwic_get_left_attr for why this isn't a plain split.
            return joined.dropFirst().components(separatedBy: "\u{1F}")
        }

        func segment(_ fetch: (String) -> UnsafeMutablePointer<CChar>?) throws -> [KWICToken] {
            let words = try decode(fetch(kwicAttr))
            var secondary = Array(repeating: [String: String](), count: words.count)
            for attribute in secondaryAttributes {
                let values = try decode(fetch(attribute))
                for (index, value) in values.enumerated() where secondary.indices.contains(index) {
                    secondary[index][attribute] = value
                }
            }
            return zip(words, secondary).map(KWICToken.init)
        }

        var lines: [KWICLine] = []
        while mtc_kwic_next(kwic) != 0 {
            // Cheap enough to do every 256 lines; instant to notice.
            if lines.count & 0xFF == 0xFF { try Task.checkCancellation() }
            lines.append(KWICLine(
                leftTokens: try segment { mtc_kwic_get_left_attr(kwic, $0, &error) },
                kwicTokens: try segment { mtc_kwic_get_kwic_attr(kwic, $0, &error) },
                rightTokens: try segment { mtc_kwic_get_right_attr(kwic, $0, &error) },
                position: Int(mtc_kwic_get_pos(kwic))
            ))
        }
        return lines
    }

    /// Top collocates of the concordance's current hits, best-scoring first.
    public func collocations(_ spec: CollocationSpec) throws -> [CollocationItem] {
        var error: UnsafeMutablePointer<CChar>?
        let measureCode = CChar(spec.measure.rawValue.asciiValue!)
        guard let items = mtc_colloc_open(
            handle, spec.attribute, measureCode,
            Int64(spec.minFrequency), Int64(spec.minCollocateFrequency),
            Int32(spec.leftWindow), Int32(spec.rightWindow), Int32(spec.maxItems), &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_colloc_close(items) }

        var results: [CollocationItem] = []
        while mtc_colloc_next(items) != 0 {
            let word = mtc_colloc_get_item(items)
            let freq = mtc_colloc_get_freq(items)
            let cnt = mtc_colloc_get_cnt(items)
            let score = mtc_colloc_get_bgr(items, measureCode)
            results.append(CollocationItem(word: String(cString: word!), freq: Int(freq), cnt: Int(cnt), score: score))
            mtc_free_string(word)
        }
        return results
    }

    /// Frequency distribution of the concordance's current hits, grouped by
    /// `criteria` (joined into one multi-level Manatee criteria string) and
    /// sorted by frequency descending. Only bins with at least `minFrequency`
    /// hits are included.
    public func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int = 1) throws -> [FrequencyItem] {
        precondition(!criteria.isEmpty, "frequencyDistribution needs at least one criterion")
        let crit = criteria.map(\.criteriaFragment).joined(separator: " ")
        // Only the *first* criterion determines whether `norm` is meaningful
        // (see Corpus::freq_dist - it looks at the first criterion's attribute).
        let normIsMeaningful = criteria[0].attribute.contains(".")

        var error: UnsafeMutablePointer<CChar>?
        guard let dist = mtc_freq_dist_open(handle, crit, Int64(minFrequency), &error) else {
            throw ManateeError.failure(consumeError(error))
        }
        defer { mtc_freq_dist_close(dist) }

        var results: [FrequencyItem] = []
        let count = Int(mtc_freq_dist_count(dist))
        results.reserveCapacity(count)
        for i in 0..<count {
            let word = mtc_freq_dist_get_word(dist, Int32(i))
            let freq = mtc_freq_dist_get_freq(dist, Int32(i))
            let norm = mtc_freq_dist_get_norm(dist, Int32(i))
            results.append(FrequencyItem(
                word: String(cString: word!), freq: Int(freq),
                norm: normIsMeaningful ? Int(norm) : nil))
            mtc_free_string(word)
        }
        return results
    }
}
