import Foundation

/// A pando query with its hits loaded (docs/pando-gui-plan.md).
///
/// pando evaluates lazily and pages, and has no live, re-orderable result set
/// like Manatee's. So this loads the first `limit` hits once - each with the
/// attributes of its match tokens and some tokens of context - and keeps a
/// *view* of them: an ordering and subset that sorting, shuffling, sampling
/// and deleting line groups change, all in memory. Collocations,
/// frequencies and region attributes are separate pando programs on the same
/// query.
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

    public var size: Int {
        loadedWindow == 0 ? min(totalHits, limit) : view.count
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

    /// Loads the hits with at least `window` tokens of context each side.
    private func ensureLoaded(window: Int) throws {
        let wanted = max(window, Self.minimumWindow)
        if loadedWindow >= wanted { return }
        let count = min(totalHits, limit)
        var fresh: [Line] = []
        if count > 0 {
            let object = try library.result(library.query(handle, query, PandoLibrary.json([
                "limit": count, "offset": 0, "total": false, "context": wanted, "attrs": attributes,
            ])))
            fresh = parse(object["hits"] as? [[String: Any]] ?? [])
        }
        if loadedWindow == 0 || fresh.count != lines.count {
            view = Array(fresh.indices)
            groups = [:]
            regionValues = [:]
        }
        lines = fresh
        loadedWindow = wanted
    }

    // MARK: Lines

    /// "-10" / "10" (token counts) as a count; anything else falls back to 10.
    private static func tokens(in context: String) -> Int {
        Int(context).map { abs($0) } ?? 10
    }

    public func kwicLines(leftContext: String, rightContext: String, kwicAttr: String,
                          secondaryAttributes: [String]) throws -> [KWICLine] {
        let left = Self.tokens(in: leftContext), right = Self.tokens(in: rightContext)
        try ensureLoaded(window: max(left, right))
        return view.map { index in
            let line = lines[index]
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

    public func sort(_ criteria: SortCriteria, unique: Bool) throws {
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
        try ensureLoaded(window: Self.minimumWindow)
        view.shuffle()
    }

    public func sample(lines count: Int) throws {
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
        guard view.indices.contains(lineIndex) else { return 0 }
        return groups[view[lineIndex]] ?? 0
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
        if loadedWindow > 0 && lines.count == totalHits {
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

    private func tabulate(offset: Int, count: Int, fields: [String]) throws -> [[String]] {
        let program = "\(query); tabulate Last \(offset) \(count) " + fields.map { "match.\($0)" }.joined(separator: ", ")
        let object = try library.result(library.run(handle, program, "{}"))
        return (object["rows"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
    }

    public func structureValues(attribute: String) throws -> [String] {
        try ensureLoaded(window: Self.minimumWindow)
        let name = PandoNames.attribute(attribute)
        if regionValues[name] == nil {
            regionValues[name] = try tabulate(offset: 0, count: lines.count, fields: [name]).map { $0.first ?? "" }
        }
        let values = regionValues[name] ?? []
        return view.map { values.indices.contains($0) ? values[$0] : "" }
    }

    public func structureInfo(forViewRow row: Int) throws -> [(structure: String, attribute: String, value: String)] {
        try ensureLoaded(window: Self.minimumWindow)
        guard view.indices.contains(row) else { return [] }
        var wanted: [(structure: String, attribute: String)] = []
        for structure in structures {
            for attribute in structure.attributes { wanted.append((structure.name, attribute)) }
        }
        guard !wanted.isEmpty else { return [] }
        let fields = wanted.map { PandoNames.attribute("\($0.structure).\($0.attribute)") }
        guard let values = try tabulate(offset: view[row], count: 1, fields: fields).first else { return [] }
        return zip(wanted, values).compactMap { entry, value in
            value.isEmpty || value == "_" ? nil : (entry.structure, entry.attribute, value)
        }
    }

    public func extendedContext(forViewRow row: Int, tokens: Int) throws -> (before: String, match: String, after: String) {
        try ensureLoaded(window: Self.minimumWindow)
        guard view.indices.contains(row) else { throw PandoError.failure("That hit isn\u{2019}t there any more.") }
        let object = try library.result(library.query(handle, query, PandoLibrary.json([
            "limit": 1, "offset": view[row], "total": false, "context": tokens, "attrs": ["form"],
        ])))
        guard let hit = (object["hits"] as? [[String: Any]])?.first, let context = hit["context"] as? [String: Any] else {
            throw PandoError.failure("pando returned no context for that hit.")
        }
        return (context["left"] as? String ?? "", context["match"] as? String ?? "", context["right"] as? String ?? "")
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

    public func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int) throws -> [FrequencyItem] {
        guard !criteria.isEmpty else { return [] }
        if criteria.contains(where: { $0.contextOffset != 0 }) {
            throw PandoError.unsupported("Frequencies at a context offset")
        }
        let fields = criteria.map { PandoNames.attribute($0.attribute) }.joined(separator: ", ")
        let object = try library.result(library.run(
            handle, "\(query); count by \(fields)", PandoLibrary.json(["limit": 100_000])))
        return (object["rows"] as? [[String: Any]] ?? []).compactMap { row in
            guard let key = row["key"] as? String, let count = row["count"] as? Int, count >= minFrequency else { return nil }
            return FrequencyItem(word: key, freq: count)
        }
    }
}
