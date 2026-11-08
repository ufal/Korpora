import Foundation

/// A pando query and a view of its hits (docs/pando-gui-plan.md).
///
/// pando evaluates lazily and pages, and through the C API it has no stored,
/// re-orderable result set like Manatee's. So there are two states.
///
/// *Windowed* (until the first operation): the view is every hit in corpus
/// order and lines are read from pando a window at a time (`offset`/`limit`),
/// so a result of millions of hits can be scrolled to its end; nothing is kept.
/// On a result larger than `limit`, pando orders it, too: a sort of one key
/// (`sort`, paged with `cat`), a shuffle or a random sample (its `shuffle`,
/// `sample` and `seed` options) leave the view windowed.
///
/// *Loaded* (after a sort, shuffle, sample or line group): the first `limit`
/// hits are loaded once - each with the attributes of its match tokens and some
/// tokens of context - and the view is an ordering and subset of them that the
/// operations change, all in memory. Every operation pando can't do on a big
/// result (several sort keys, retrograde, unique, line groups, a sort of a
/// sample) works that way on the first `limit` hits of the current view.
///
/// Collocations, frequencies and region attributes are separate pando programs
/// on the same query.
///
/// Owns its own engine handle, so it can be cancelled from another thread and
/// never shares a handle between threads.
public actor PandoConcordance: ConcordanceHandle {
    /// One hit as loaded.
    private struct Line {
        var position: Int
        var left: [String]
        var match: [[String: String]]
        var matchWords: [String]
        var right: [String]
    }

    private let library: PandoLibrary
    nonisolated(unsafe) private let handle: OpaquePointer
    private let query: String
    private let limit: Int
    private let attributes: [String]
    private let structures: [StructureInfo]

    public let totalHits: Int
    /// Hits loaded, in corpus order (what the engine returned for the first `limit`).
    private var lines: [Line] = []
    private var loadedWindow = 0
    /// Indices into `lines`: the current order and subset.
    private var view: [Int] = []
    /// Line group of each line (index into `lines`).
    private var groups: [Int: Int] = [:]
    private var regionValues: [String: [String]] = [:]

    /// Tokens of context loaded per hit, at least; sort keys may reach this far.
    static let minimumWindow = 20

    init(corpus: PandoCorpus, query: String, limit: Int) async throws {
        let library = corpus.library
        self.library = library
        let handle = try library.openHandle(directory: corpus.directory)
        self.handle = handle
        self.query = query
        self.limit = max(limit, 1)
        let info = try await corpus.info()
        attributes = info.attributes
        structures = info.structures
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
        totalHits = counted
    }

    deinit { library.close(handle) }

    /// No in-memory operation yet: the view is read from pando as needed.
    private var windowed = true

    /// How pando orders the windowed view. Only a result larger than `limit` leaves corpus order
    /// that way; a smaller one is sorted, shuffled and sampled in memory, with every option.
    private enum Order { case corpus, sorted, shuffled }
    private var order = Order.corpus
    /// A random sample of this many hits (pando's `sample`), in corpus order or shuffled.
    private var sampleSize: Int?
    /// Fixes the shuffle and the sample, so every window and reload sees the same hits.
    private var seed = PandoConcordance.newSeed()
    /// The name the sorted hits have in the engine handle's session (for `cat`).
    private static let sortedSet = "KorporaHits"
    private static func newSeed() -> UInt32 { UInt32.random(in: 1...UInt32.max) }

    /// pando orders it (a result larger than the in-memory limit).
    private var pandoOrders: Bool { totalHits > limit }

    /// Hits the windowed view has.
    private var windowedSize: Int { min(sampleSize ?? totalHits, totalHits) }

    /// How many hits were loaded when the view went into memory, and whether that is fewer than the view had.
    private var loadedCount = 0
    public private(set) var viewIsPartial = false

    public var size: Int {
        windowed ? windowedSize : view.count
    }

    /// The index into `lines` of view row `row`, or (windowed) the row itself: the hit's number in the
    /// view's own order.
    private func sourceIndex(forRow row: Int) -> Int? {
        if windowed { return (0..<windowedSize).contains(row) ? row : nil }
        return view.indices.contains(row) ? view[row] : nil
    }

    /// `count` hits of the view's own order (corpus, sorted by pando, shuffled, sampled) from `offset`.
    private func hitPage(offset: Int, count: Int, context: Int, attrs: [String], sentence: Bool = false)
        throws -> [[String: Any]] {
        let object: [String: Any]
        if order == .sorted {
            var options: [String: Any] = ["context": context, "attrs": attrs]
            if sentence { options["sentence"] = true }
            object = try library.result(library.run(
                handle, "cat \(Self.sortedSet) \(offset) \(offset + count - 1)", PandoLibrary.json(options)))
        } else {
            var options: [String: Any] = [
                "limit": count, "offset": offset, "total": false, "context": context, "attrs": attrs,
            ]
            if sentence { options["sentence"] = true }
            if let sampleSize { options["sample"] = sampleSize }
            if order == .shuffled { options["shuffle"] = true }
            if order == .shuffled || sampleSize != nil { options["seed"] = Int(seed) }
            object = try library.result(library.query(handle, query, PandoLibrary.json(options)))
        }
        return object["hits"] as? [[String: Any]] ?? []
    }

    // MARK: Loading

    private static func words(_ text: String?) -> [String] {
        (text ?? "").split(separator: " ").map(String.init)
    }

    private func parse(_ hits: [[String: Any]]) -> [Line] {
        hits.map { hit in
            let context = hit["context"] as? [String: Any]
            let start = hit["match_start"] as? Int ?? 0
            let end = hit["match_end"] as? Int ?? start
            let matchWords = Self.words(context?["match"] as? String)
            var byPosition: [Int: [String: String]] = [:]
            for token in hit["tokens"] as? [[String: Any]] ?? [] {
                guard let position = token["pos"] as? Int else { continue }
                byPosition[position] = token.compactMapValues { value -> String? in
                    if let text = value as? String { return text }
                    if let number = value as? Int { return String(number) }
                    return nil
                }
            }
            // Every position of the match gets a token: the loaded attributes where pando
            // returned them, else just the word (a gap in the pattern).
            let match: [[String: String]] = (start...max(start, end)).enumerated().map { offset, position in
                var token = byPosition[position] ?? [:]
                if token["form"] == nil, offset < matchWords.count, matchWords.count == end - start + 1 {
                    token["form"] = matchWords[offset]
                }
                return token
            }
            return Line(position: start, left: Self.words(context?["left"] as? String), match: match,
                        matchWords: matchWords, right: Self.words(context?["right"] as? String))
        }
    }

    /// Whether the hits were loaded with their sentence as context (`sentence`), not a token window.
    private var loadedSentence = false

    /// Loads the hits with at least `window` tokens of context each side, or their sentence (`sentence` true;
    /// nil: whichever is loaded - a sort or a line group doesn't care).
    private func ensureLoaded(window: Int, sentence: Bool? = nil) throws {
        let wanted = max(window, Self.minimumWindow)
        let wantSentence = sentence ?? loadedSentence
        if loadedWindow >= wanted, loadedSentence == wantSentence { return }
        if windowed {
            loadedCount = min(windowedSize, limit)
            viewIsPartial = loadedCount < windowedSize
        }
        let count = loadedCount
        var fresh: [Line] = []
        if count > 0 {
            fresh = parse(try hitPage(offset: 0, count: count, context: wanted, attrs: attributes, sentence: wantSentence))
        }
        if loadedWindow == 0 || fresh.count != lines.count {
            view = Array(fresh.indices)
            groups = [:]
            regionValues = [:]
        }
        lines = fresh
        loadedWindow = wanted
        loadedSentence = wantSentence
        windowed = false
    }

    // MARK: Lines

    /// "-10" / "10" (token counts) as a count; anything else falls back to 10.
    private static func tokens(in context: String) -> Int {
        Int(context).map { abs($0) } ?? 10
    }

    /// "-1:s" / "1:s": up to the sentence boundary (Manatee's context spec for a structure).
    private static func isSentence(_ context: String) -> Bool { context.hasSuffix(":s") }

    /// One loaded hit as a display line.
    private func kwicLine(_ line: Line, left: Int, right: Int, kwicAttr: String,
                          secondaryAttributes: [String]) -> KWICLine {
        func plain(_ words: [String]) -> [KWICToken] {
            words.map { KWICToken(word: $0, secondaryAttributes: [:]) }
        }
        let kwic = line.match.enumerated().map { offset, token -> KWICToken in
            var secondary: [String: String] = [:]
            for name in secondaryAttributes { if let value = token[name] { secondary[name] = value } }
            let word = token[kwicAttr] ?? (offset < line.matchWords.count ? line.matchWords[offset] : "")
            return KWICToken(word: word, secondaryAttributes: secondary)
        }
        return KWICLine(leftTokens: plain(Array(line.left.suffix(left))), kwicTokens: kwic,
                        rightTokens: plain(Array(line.right.prefix(right))), position: line.position)
    }

    public func kwicLines(range: Range<Int>, leftContext: String, rightContext: String, kwicAttr: String,
                          secondaryAttributes: [String]) throws -> [KWICLine] {
        let sentence = Self.isSentence(leftContext) || Self.isSentence(rightContext)
        // A sentence has no fixed length: every token pando gives is kept.
        let left = sentence ? Int.max : Self.tokens(in: leftContext)
        let right = sentence ? Int.max : Self.tokens(in: rightContext)
        let rows = range.clamped(to: 0..<size)
        guard !rows.isEmpty else { return [] }
        if windowed {
            var attrs = secondaryAttributes
            if !attrs.contains(kwicAttr) { attrs.append(kwicAttr) }
            let hits = try hitPage(offset: rows.lowerBound, count: rows.count,
                                   context: sentence ? Self.minimumWindow : max(left, right), attrs: attrs,
                                   sentence: sentence)
            return parse(hits).map {
                kwicLine($0, left: left, right: right, kwicAttr: kwicAttr, secondaryAttributes: secondaryAttributes)
            }
        }
        try ensureLoaded(window: sentence ? Self.minimumWindow : max(left, right), sentence: sentence)
        return rows.map { row in
            kwicLine(lines[view[row]], left: left, right: right, kwicAttr: kwicAttr,
                     secondaryAttributes: secondaryAttributes)
        }
    }

    // MARK: Operations

    private func sortKey(_ line: Line, _ level: SortLevel) throws -> String {
        let attribute = level.attribute
        var parts: [String]
        switch level.anchor {
        case .kwic:
            parts = [line.match.first?[attribute] ?? ""]
        case .left, .right:
            guard attribute == "form" else {
                throw PandoError.unsupported("Sorting by \u{201C}\(attribute)\u{201D} of the words around the hit")
            }
            parts = level.anchor == .left ? Array(line.left.suffix(level.span).reversed()) : Array(line.right.prefix(level.span))
        }
        var key = parts.joined(separator: " ")
        if level.reverse { key = String(key.reversed()) }
        return key
    }

    /// pando's own `sort` for what it can do on a big result: one key, ascending, no retrograde, not unique.
    private func pandoSort(_ criteria: SortCriteria, unique: Bool) -> String? {
        guard criteria.levels.count == 1, let level = criteria.levels.first, !level.reverse, !unique else { return nil }
        var sort = "sort \(Self.sortedSet) by \(PandoNames.attribute(level.attribute))"
        if level.caseInsensitive { sort += " %c" }
        switch level.anchor {
        case .kwic: break
        case .left: sort += " on match[-1]..match[-\(level.span)]"
        case .right: sort += " on matchend[1]..matchend[\(level.span)]"
        }
        return sort
    }

    public func sort(_ criteria: SortCriteria, unique: Bool) async throws {
        if windowed, pandoOrders, sampleSize == nil, let sort = pandoSort(criteria, unique: unique) {
            // pando sorts the whole result once (seconds for millions of hits; a cancel reaches it from
            // another thread) and then pages it with `cat` in milliseconds.
            let program = "\(Self.sortedSet) = \(query); \(sort)"
            let library = library, handle = handle
            _ = try await withTaskCancellationHandler {
                try library.result(library.run(handle, program, PandoLibrary.json(["limit": 1])))
            } onCancel: {
                library.cancel(handle)
            }
            try Task.checkCancellation()
            order = .sorted
            return
        }
        try ensureLoaded(window: Self.minimumWindow)
        let levels = criteria.levels
        let locale = Locale.current
        var keys: [Int: [String]] = [:]
        for index in view { keys[index] = try levels.map { try sortKey(lines[index], $0) } }
        func compare(_ a: Int, _ b: Int) -> ComparisonResult {
            for (position, level) in levels.enumerated() {
                let order = keys[a]![position].compare(
                    keys[b]![position], options: level.caseInsensitive ? [.caseInsensitive] : [], range: nil, locale: locale)
                if order != .orderedSame { return order }
            }
            return .orderedSame
        }
        view.sort { a, b in
            let order = compare(a, b)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
        if unique {
            var kept: [Int] = []
            for index in view where kept.last.map({ compare($0, index) != .orderedSame }) ?? true { kept.append(index) }
            view = kept
        }
    }

    public func shuffle() throws {
        if windowed, pandoOrders {
            order = .shuffled
            seed = Self.newSeed()
            return
        }
        try ensureLoaded(window: Self.minimumWindow)
        view.shuffle()
    }

    public func sample(lines count: Int) throws {
        if windowed, pandoOrders, order != .sorted {
            guard count < windowedSize else { return }
            sampleSize = max(count, 0)
            return
        }
        try ensureLoaded(window: Self.minimumWindow)
        guard count < view.count else { return }
        let chosen = Set(view.indices.shuffled().prefix(max(count, 0)))
        view = view.indices.filter { chosen.contains($0) }.map { view[$0] }
    }

    public func setLineGroup(rangeStart: Int, rangeLen: Int, group: Int) throws {
        try ensureLoaded(window: Self.minimumWindow)
        guard rangeStart >= 0, rangeLen > 0, rangeStart < view.count else { return }
        for row in rangeStart..<min(rangeStart + rangeLen, view.count) {
            if group == 0 { groups[view[row]] = nil } else { groups[view[row]] = group }
        }
    }

    public func linegroup(at lineIndex: Int) -> Int {
        guard !windowed, view.indices.contains(lineIndex) else { return 0 }
        return groups[view[lineIndex]] ?? 0
    }

    public func lineGroupCounts() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        guard !windowed else { return counts }
        for index in view { if let group = groups[index], group != 0 { counts[group, default: 0] += 1 } }
        return counts
    }

    public func deleteLineGroups(_ groupNumbers: [Int], invert: Bool) throws {
        try ensureLoaded(window: Self.minimumWindow)
        let chosen = Set(groupNumbers)
        view = view.filter { index in
            let inChosen = chosen.contains(groups[index] ?? 0)
            return invert ? inChosen : !inChosen
        }
    }

    // MARK: Positions

    public func hitHistogram(bins: Int, corpusSize: Int) throws -> [Int] {
        guard bins > 0, corpusSize > 0 else { throw PandoError.failure("A histogram needs bins and a corpus size.") }
        var counts = [Int](repeating: 0, count: bins)
        func add(_ position: Int) {
            counts[min(max(position * bins / corpusSize, 0), bins - 1)] += 1
        }
        if !windowed && lines.count == totalHits {
            for index in view { add(lines[index].position) }
            return counts
        }
        // Not every hit is loaded: read the positions of all of them, a page at a time.
        let page = 50_000
        var offset = 0
        while offset < totalHits {
            try Task.checkCancellation()
            let object = try library.result(library.query(handle, query, PandoLibrary.json([
                "limit": page, "offset": offset, "total": false, "context": 0, "attrs": ["form"],
            ])))
            let hits = object["hits"] as? [[String: Any]] ?? []
            if hits.isEmpty { break }
            for hit in hits { add(hit["match_start"] as? Int ?? 0) }
            offset += hits.count
        }
        return counts
    }

    // MARK: Region attributes and wide context

    /// Region values of `count` hits of the view's own order from `offset`; nil when pando can't give them
    /// for this order (the hits of a big result that pando shuffled or sampled: its hit pages carry no region
    /// values, and a hit's number in corpus order isn't known).
    private func tabulate(offset: Int, count: Int, fields: [String]) throws -> [[String]]? {
        let columns = fields.map { "match.\($0)" }.joined(separator: ", ")
        let program: String
        switch (order, sampleSize) {
        case (.sorted, _): program = "tabulate \(Self.sortedSet) \(offset) \(count) \(columns)"
        case (.corpus, nil): program = "\(query); tabulate Last \(offset) \(count) \(columns)"
        default: return nil
        }
        let object = try library.result(library.run(handle, program, "{}"))
        return (object["rows"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
    }

    public func structureValues(attribute: String, range: Range<Int>) throws -> [String] {
        let rows = range.clamped(to: 0..<size)
        guard !rows.isEmpty else { return [] }
        let name = PandoNames.attribute(attribute)
        if windowed {
            if let table = try tabulate(offset: rows.lowerBound, count: rows.count, fields: [name]) {
                return table.map { $0.first ?? "" }
            }
            // A shuffled or sampled big result: pando has no cheap lookup of a hit's region, but a hit page names
            // the document (the text region's id, for corpora built from several files) with every hit.
            if name == "text_id" {
                return try hitPage(offset: rows.lowerBound, count: rows.count, context: 0, attrs: ["form"])
                    .map { $0["doc_id"] as? String ?? "" }
            }
            throw PandoError.unsupported("Region values of shuffled or sampled hits in a result this large")
        }
        if regionValues[name] == nil {
            regionValues[name] = try tabulate(offset: 0, count: lines.count, fields: [name])
                .map { $0.map { $0.first ?? "" } } ?? [String](repeating: "", count: lines.count)
        }
        let values = regionValues[name] ?? []
        return rows.map { values.indices.contains(view[$0]) ? values[view[$0]] : "" }
    }

    public func structureInfo(forViewRow row: Int) throws -> [(structure: String, attribute: String, value: String)] {
        guard let index = sourceIndex(forRow: row) else { return [] }
        var wanted: [(structure: String, attribute: String)] = []
        for structure in structures {
            for attribute in structure.attributes { wanted.append((structure.name, attribute)) }
        }
        guard !wanted.isEmpty else { return [] }
        let fields = wanted.map { PandoNames.attribute("\($0.structure).\($0.attribute)") }
        guard let rows = try tabulate(offset: index, count: 1, fields: fields) else {
            throw PandoError.unsupported("The document of a shuffled or sampled hit in a result this large")
        }
        guard let values = rows.first else { return [] }
        return zip(wanted, values).compactMap { entry, value in
            value.isEmpty || value == "_" ? nil : (entry.structure, entry.attribute, value)
        }
    }

    public func extendedContext(forViewRow row: Int, tokens: Int) throws -> (before: String, match: String, after: String) {
        guard let index = sourceIndex(forRow: row) else { throw PandoError.failure("That hit isn\u{2019}t there any more.") }
        guard let hit = try hitPage(offset: index, count: 1, context: tokens, attrs: ["form"]).first,
              let context = hit["context"] as? [String: Any] else {
            throw PandoError.failure("pando returned no context for that hit.")
        }
        return (context["left"] as? String ?? "", context["match"] as? String ?? "", context["right"] as? String ?? "")
    }

    public func hitNodes(forViewRow row: Int, context: Int, attributes: [String]) throws -> HitNodes {
        guard let index = sourceIndex(forRow: row) else { throw PandoError.failure("That hit isn\u{2019}t there any more.") }
        var attrs = attributes
        if !attrs.contains("form") { attrs.append("form") }
        guard let hit = try hitPage(offset: index, count: 1, context: context, attrs: attrs).first,
              let text = hit["context"] as? [String: Any] else {
            throw PandoError.failure("pando returned no context for that hit.")
        }
        func split(_ key: String) -> [String] {
            (text[key] as? String ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }
        let left = split("left"), match = split("match"), right = split("right")
        let start = hit["match_start"] as? Int ?? 0
        let tokens: [HitNodes.Token] = (hit["tokens"] as? [[String: Any]] ?? []).compactMap { token in
            guard let position = token["pos"] as? Int else { return nil }
            let offset = position - start
            guard match.indices.contains(offset) else { return nil }
            var values: [String: String] = [:]
            for attribute in attributes {
                if let value = token[attribute] as? String { values[attribute] = value }
            }
            return HitNodes.Token(wordIndex: left.count + offset, attributes: values)
        }
        return HitNodes(words: left + match + right, matchRange: left.count..<(left.count + match.count), tokens: tokens)
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
            handle, "\(query); coll by \(PandoNames.attribute(spec.attribute))", PandoLibrary.json([
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

    /// The most combinations a frequency over several fields keeps. pando's `freq` sends every combination
    /// (it has no row limit, and `limit` doesn't apply: 712,305 noun lemmas in the UD release came back whole),
    /// by count, so the table keeps the first rows and says it was cut.
    static let frequencyRowLimit = 100_000

    public func frequencyTable(_ fields: [FrequencyField], minFrequency: Int) throws -> FrequencyTable {
        let program = try QueryNodes(query).frequencyProgram(for: fields)
        let object = try library.result(library.run(handle, program, PandoLibrary.json([:])))
        let rawRows = object["rows"] as? [[String: Any]] ?? []
        let rows: [FrequencyRow] = rawRows.compactMap { row in
            guard let key = row["key"] as? String, let count = row["count"] as? Int else { return nil }
            var values = key.components(separatedBy: "\t")
            // A value with a tab in it would shift the columns: keep the shape of the table.
            if values.count > fields.count {
                values = Array(values[..<(fields.count - 1)]) + [values[(fields.count - 1)...].joined(separator: "\t")]
            }
            while values.count < fields.count { values.append("") }
            let percent = (row["pct"] as? Double) ?? (row["pct"] as? Int).map(Double.init) ?? 0
            let perMillion = (row["ipm"] as? Double) ?? (row["ipm"] as? Int).map(Double.init)
            return FrequencyRow(values: values, count: count, percent: percent, perMillion: perMillion,
                                norm: row["subcorpus_size"] as? Int)
        }
        let total = object["total_matches"] as? Int ?? rows.reduce(0) { $0 + $1.count }
        var table = FrequencyTable(fields: fields, rows: rows, totalMatches: total).folded()
        if minFrequency > 1 { table.rows = table.rows.filter { $0.count >= minFrequency } }
        if table.rows.count > Self.frequencyRowLimit {
            table.rows = Array(table.rows.prefix(Self.frequencyRowLimit))
            table.isCut = true
        }
        return table
    }

    public func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int) throws -> [FrequencyItem] {
        guard !criteria.isEmpty else { return [] }
        if criteria.contains(where: { $0.contextOffset != 0 }) {
            throw PandoError.unsupported("Frequencies at a context offset")
        }
        let fields = criteria.map { PandoNames.attribute($0.attribute) }.joined(separator: ", ")
        // `freq` is `count` plus the relative frequency: per million tokens of the corpus, or for a document
        // property of that value's documents (`subcorpus_size`).
        let object = try library.result(library.run(
            handle, "\(query); freq by \(fields)", PandoLibrary.json(["limit": 100_000])))
        return (object["rows"] as? [[String: Any]] ?? []).compactMap { row in
            guard let key = row["key"] as? String, let count = row["count"] as? Int, count >= minFrequency else { return nil }
            let perMillion = (row["ipm"] as? Double) ?? (row["ipm"] as? Int).map(Double.init)
            return FrequencyItem(word: key, freq: count, norm: row["subcorpus_size"] as? Int, perMillion: perMillion)
        }
    }
}
