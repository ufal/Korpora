import Cocoa
import KorporaEngine

struct ConcordanceRow {
    let id: Int
    /// Where this line is in the engine's view (an `id` is a display position, which a descending
    /// sort reverses; engine lookups - region attributes, wide context - go by this).
    let viewIndex: Int
    let line: KWICLine
    let group: Int
    /// The value of `ConcordanceDocument.structuralAttributeToShow` for
    /// this line's enclosing structure - nil if that setting is itself
    /// nil, or if this line's structure has no value for it.
    let structuralAttributeValue: String?

    init(id: Int, line: KWICLine, group: Int, structuralAttributeValue: String? = nil, viewIndex: Int? = nil) {
        self.id = id
        self.viewIndex = viewIndex ?? id
        self.line = line
        self.group = group
        self.structuralAttributeValue = structuralAttributeValue
    }
}

/// How "Extended Context…" (Phase 6.6) presents a hit's wider context - a
/// global preference (`AppSettings.extendedContextDisplayMode`), not a
/// per-document one, since it's purely about presentation, not data.
enum ExtendedContextDisplayMode: String, Codable {
    /// An independent, non-modal window
    /// (`ExtendedContextWindowController`) - the original 6.6 behavior
    /// was a modal sheet; switched to a plain window once multiple could
    /// need to stay open at once (`AppSettings
    /// .allowMultipleExtendedContexts`), which a sheet can't support (at
    /// most one per parent window). Kept the `sheet` case name/rawValue
    /// for UserDefaults backward compatibility - the Settings UI now
    /// labels it "Window".
    case sheet
    /// The clicked row itself grows in place into a word-wrapped
    /// paragraph, right in the table - added after the user asked for it
    /// as an alternative to the sheet.
    case inline
}

/// The persisted content is the query, not the materialized rows - stable
/// and small regardless of result-set size, and the base that the
/// `operations` chain (see `ConcordanceOperation`) replays against. See
/// docs/project-plan.md's NSDocument model section.
final class ConcordanceDocument: NSDocument {
    static let typeName = "cz.cuni.mff.ufal.korpora.concordance"

    /// Where `runQuery` records the query history: the app's own defaults,
    /// except in tests.
    var historyDefaults: UserDefaults = .standard

    /// The engine corpora are opened with; tests can substitute a fake.
    var engine: any CorpusEngine = Engines.default

    var corpusName: String = ""
    /// A part of the corpus (a saved restriction) to search instead of all of it, or nil.
    var subcorpus: Subcorpus?
    var initialQuery: String = ""
    // Defaults come from AppSettings (Phase 6.4's Concordance settings
    // tab) at instance-creation time - correct for both a brand-new
    // document (nothing else sets these beforehand) and a reopened saved
    // one (`read(from:)` immediately overwrites them anyway).
    var leftContext = "-\(AppSettings.shared.defaultLeftContext)"
    var rightContext = "\(AppSettings.shared.defaultRightContext)"
    /// The attribute shown as each token (`form` for pando corpora; set from the corpus when a search runs
    /// if the saved one isn't there).
    var kwicAttr = "form"
    /// The corpus's own token-text attribute (`form`); what words around a hit are sorted by. Read
    /// from the corpus when a search runs.
    private(set) var textAttribute = "form"
    /// The corpus's token attributes, for menus (sorting, display). Read when a search runs.
    private(set) var attributeNames: [String] = []
    /// Additional positional attributes (e.g. "lemma", "tag") shown
    /// alongside `kwicAttr` per token - see `KWICFormatter`. Independent,
    /// not an either/or mode: an attribute can be in both lists at once
    /// (shown inline *and* repeated in the hover tooltip), one only, or
    /// neither. Both empty by default: no visual change from before this
    /// feature existed.
    var inlineAttributes: [String] = []
    var tooltipAttributes: [String] = []
    /// A structural attribute (e.g. "doc.title") shown as its own column
    /// on every row - constant for the whole line (one enclosing document
    /// per hit), unlike `inlineAttributes`/`tooltipAttributes` which vary
    /// per token, so this doesn't feed `attributesToFetch`/`KWICFormatter`
    /// at all - it's fetched separately per row in `buildRows`. There's
    /// only ever one "Doc" column, so this is a single value, not a list
    /// - see `AttributeDisplayPopoverController`'s radio-button choice.
    var structuralAttributeToShow: String?

    /// The deduplicated union of both lists, in first-seen order - what
    /// actually needs fetching from the engine, since both lists need real
    /// per-token values regardless of which one(s) an attribute is in.
    private var attributesToFetch: [String] {
        var seen = Set<String>()
        return (inlineAttributes + tooltipAttributes).filter { seen.insert($0).inserted }
    }

    private(set) var operations: [ConcordanceOperation] = []
    private(set) var status: String = ""

    // MARK: - Rows, read a window at a time

    /// Rows are fetched from the engine in chunks as the table scrolls to them, so a result of
    /// millions of hits needs no more memory than a few screens (the way Manatee/KonText make only the
    /// requested page of lines). `rowCount` is every row; `row(at:)` the loaded ones.
    static let rowChunk = 200
    /// Chunks kept; the ones farthest from where the table is reading are dropped beyond this.
    private static let cachedChunkLimit = 100

    /// Rows in the current view (every hit until an operation shrinks it).
    private(set) var rowCount = 0
    private var rowChunks: [Int: [ConcordanceRow]] = [:]
    private var chunksBeingFetched: Set<Int> = []
    /// Bumped when the cached rows go stale (a new result, a changed display setting).
    private var rowsGeneration = 0
    private var rowSource: RowSource?

    /// What fetching a row needs, as it was when the result or its display last changed.
    private struct RowSource {
        let live: any ConcordanceHandle
        let count: Int
        let leftContext: String
        let rightContext: String
        let kwicAttr: String
        let secondaryAttributes: [String]
        let structuralAttribute: String?
        /// A descending sort shows the engine's view backwards: row `i` is view row `count - 1 - i`.
        let descending: Bool
    }

    /// The loaded rows, in order (all of them for a small result; for a big one the chunks nearest the
    /// last place the table read).
    var rows: [ConcordanceRow] { rowChunks.keys.sorted().flatMap { rowChunks[$0] ?? [] } }

    /// Called with the display rows that just arrived, so the table can redraw them.
    var onRowsLoaded: ((Range<Int>) -> Void)?

    /// A row that is loaded; nil (and a fetch in the background) when it isn't yet.
    func row(at index: Int) -> ConcordanceRow? {
        guard index >= 0, index < rowCount else { return nil }
        if let chunk = rowChunks[index / Self.rowChunk], chunk.indices.contains(index % Self.rowChunk) {
            return chunk[index % Self.rowChunk]
        }
        requestRows(around: index)
        return nil
    }

    /// The engine's view row behind display row `row`.
    private func viewIndex(forRow row: Int) -> Int {
        (rowSource?.descending ?? false) ? rowCount - 1 - row : row
    }

    /// Fetches the chunk holding `index` (and the next one, so a scroll finds it ready) unless present.
    func requestRows(around index: Int) {
        guard let source = rowSource else { return }
        let first = index / Self.rowChunk
        for chunk in first...(first + 1) where chunk * Self.rowChunk < rowCount {
            guard rowChunks[chunk] == nil, !chunksBeingFetched.contains(chunk) else { continue }
            chunksBeingFetched.insert(chunk)
            let generation = rowsGeneration
            let range = (chunk * Self.rowChunk)..<min((chunk + 1) * Self.rowChunk, rowCount)
            Task { @MainActor in
                let rows = try? await Self.fetchRows(range, from: source)
                guard generation == rowsGeneration else { return }
                chunksBeingFetched.remove(chunk)
                guard let rows else { return }
                rowChunks[chunk] = rows
                evictChunks(keepingNear: chunk)
                onRowsLoaded?(range)
            }
        }
    }

    private func evictChunks(keepingNear chunk: Int) {
        guard rowChunks.count > Self.cachedChunkLimit else { return }
        let farthest = rowChunks.keys.sorted { abs($0 - chunk) > abs($1 - chunk) }
        for stale in farthest.prefix(rowChunks.count - Self.cachedChunkLimit) { rowChunks[stale] = nil }
    }

    /// Display rows `range` of `source`'s view, with their line groups and region values.
    private static func fetchRows(_ range: Range<Int>, from source: RowSource) async throws -> [ConcordanceRow] {
        let engineRange = source.descending ? (source.count - range.upperBound)..<(source.count - range.lowerBound) : range
        var lines = try await source.live.kwicLines(
            range: engineRange, leftContext: source.leftContext, rightContext: source.rightContext,
            kwicAttr: source.kwicAttr, secondaryAttributes: source.secondaryAttributes)
        var regionValues: [String] = []
        if let attribute = source.structuralAttribute {
            regionValues = (try? await source.live.structureValues(attribute: attribute, range: engineRange)) ?? []
        }
        if source.descending {
            lines.reverse()
            regionValues.reverse()
        }
        var rows: [ConcordanceRow] = []
        rows.reserveCapacity(lines.count)
        for (offset, line) in lines.enumerated() {
            try Task.checkCancellation()
            let row = range.lowerBound + offset
            let viewRow = source.descending ? source.count - 1 - row : row
            let value = regionValues.indices.contains(offset) ? regionValues[offset] : ""
            rows.append(ConcordanceRow(
                id: row, line: line, group: await source.live.linegroup(at: viewRow),
                structuralAttributeValue: value.isEmpty || value == "_" ? nil : value, viewIndex: viewRow))
        }
        return rows
    }

    /// The first screens of rows from `live`, fetched before the result is shown (`setRows` shows them).
    private func firstRows(live: any ConcordanceHandle, descending: Bool) async throws
        -> (rows: [ConcordanceRow], count: Int, source: RowSource) {
        let count = await live.size
        let source = RowSource(
            live: live, count: count, leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr,
            secondaryAttributes: attributesToFetch, structuralAttribute: structuralAttributeToShow,
            descending: descending)
        let first = try await Self.fetchRows(0..<min(count, 2 * Self.rowChunk), from: source)
        try Task.checkCancellation()
        return (first, count, source)
    }

    private func setRows(_ first: [ConcordanceRow], count: Int, source: RowSource?) {
        rowsGeneration += 1
        chunksBeingFetched = []
        rowChunks = [:]
        for start in stride(from: 0, to: first.count, by: Self.rowChunk) {
            rowChunks[start / Self.rowChunk] = Array(first[start..<min(start + Self.rowChunk, first.count)])
        }
        rowCount = count
        rowSource = source
    }

    /// Every row in order, in chunks, for exporting: nothing is kept.
    func forEachRow(chunkSize: Int = 2_000, _ body: ([ConcordanceRow]) throws -> Void) async throws {
        guard let source = rowSource else { return }
        var start = 0
        while start < source.count {
            try Task.checkCancellation()
            let rows = try await Self.fetchRows(start..<min(start + chunkSize, source.count), from: source)
            try body(rows)
            start += chunkSize
        }
    }

    /// How many lines are in each line group.
    func lineGroupCounts() async -> [Int: Int] {
        await liveConcordance?.lineGroupCounts() ?? [:]
    }

    /// The corpus (and subcorpus) the results are from, for headings.
    var corpusLabel: String {
        guard let subcorpus else { return corpusName }
        return "\(corpusName), subcorpus \u{201C}\(subcorpus.name)\u{201D}"
    }

    /// What every printout says about where it came from: what it is, the
    /// corpus, the query, and how many hits (`status`).
    func printContext(_ what: String) -> [String] {
        var lines = ["\(what) \u{2013} \(corpusLabel)", "Query: \(initialQuery)"]
        if !status.isEmpty { lines.append(status) }
        return lines
    }

    /// The `LiveConcordance` behind the most recently *successful* replay -
    /// kept around (rather than discarded once `rows` is fetched, as before)
    /// so Phase 3 features (collocations, frequency distributions) have a
    /// live handle reflecting the document's current sort/filter/sample/
    /// line-group state to run against, without re-executing the whole
    /// operation chain from scratch. `nil` before the first successful query
    /// and after a failed replay (see `replay()`'s catch branch).
    private var liveConcordance: (any ConcordanceHandle)?

    /// The `Corpus` (or opened subcorpus) behind the most recent successful
    /// replay - kept around, same reasoning as `liveConcordance`, so
    /// `structuralInfo(at:)` can look up a specific hit's enclosing
    /// structural attributes (e.g. "doc.author") on demand later, without
    /// needing a live `LiveConcordance`/iterator (structural lookups are
    /// pure `Corpus`-level position queries - see `KWICLine.position`).
    private var queryCorpus: (any CorpusHandle)?

    /// Once any line-group operation exists, sort/filter/shuffle/sample are
    /// disabled - mirrors KonText's own mutual-exclusion rule, since a fresh
    /// sort/sample would silently invalidate the view line-group
    /// assignments are keyed to (Manatee resets/discards the view on some of
    /// those operations - see `LiveConcordance.sample`'s doc comment).
    var hasLineGroups: Bool { operations.contains { $0.isLineGroupOperation } }

    /// The view controller sets this to learn when `rows`/`status` change.
    /// `animated` is false for a display-only refetch (`refetchDisplay()`,
    /// behind `setContext`/`setAttributeDisplay`) - animating a diffable
    /// snapshot apply while a toolbar popover is *also* closing (its own
    /// Core Animation transition) raced with that transition and produced
    /// "Invalid attempt to open a new transaction during CA commit"
    /// warnings, found via manual testing 2026-09-07. A display-only
    /// refetch never adds/removes/reorders rows anyway - only their
    /// content changes - so there's nothing worth animating here even
    /// setting the bug aside.
    var onResultsChanged: ((_ animated: Bool) -> Void)?

    private weak var windowController: ConcordanceWindowController?

    override class var autosavesInPlace: Bool { true }

    /// A concordance is disposable scratch state by default - like a
    /// KonText tab, not a file the user must explicitly keep or discard.
    /// NSDocument's default `isDocumentEdited` tracks the undo manager, and
    /// every `setOperations` call (sort/filter/shuffle/sample/line-group)
    /// registers an undo action - so without this override, touching any
    /// toolbar control would dirty the document and closing/quitting would
    /// prompt to Save/Delete/Cancel. Explicit File > Save still works (see
    /// `validateUserInterfaceItem` below), independent of this override.
    override var isDocumentEdited: Bool { false }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSDocument.save(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func makeWindowControllers() {
        let controller = ConcordanceWindowController(document: self)
        windowController = controller
        addWindowController(controller)
        if initialQuery.isEmpty {
            // A brand-new, parameterless document - ask for a corpus + CQL
            // query once the window has actually been shown (AppKit calls
            // `showWindows()` right after this method returns, whether the
            // document was created via our own code or its own automatic
            // untitled-document-at-launch path).
            DispatchQueue.main.async { [weak self] in self?.presentNewConcordanceSheet() }
        } else {
            replay()
        }
    }

    /// Presents the corpus/query picker for a brand-new document.
    func presentNewConcordanceSheet() {
        guard let contentViewController = windowController?.window?.contentViewController else { return }
        let sheet = NewConcordanceSheetController()
        sheet.corpusName = corpusName
        sheet.query = initialQuery
        sheet.onCommit = { [weak self] corpus, subcorpus, cql in
            guard let self else { return }
            corpusName = corpus
            self.subcorpus = subcorpus
            runQuery(cql)
        }
        sheet.onCancel = { [weak self] in
            guard let self, initialQuery.isEmpty else { return }
            windowController?.close()
        }
        contentViewController.presentAsSheet(sheet)
    }

    /// Runs a brand-new query, discarding any operation chain - used for the
    /// initial "New Concordance" sheet and for re-running the query bar.
    func runQuery(_ cql: String) {
        initialQuery = cql
        operations = []
        // Recorded unconditionally (see QueryHistoryStore's doc comment) -
        // this covers both the initial "New Concordance" sheet's Search
        // button (which sets corpusName/subcorpus then calls this) and
        // the persistent query bar's re-run, with no separate call site
        // needed at either.
        QueryHistoryStore.record(
            corpusName: corpusName, subcorpusName: subcorpus?.name, query: cql, defaults: historyDefaults)
        replay()
    }

    // MARK: - Operations (each undoable - see `ConcordanceOperation`)

    func performSort(_ criteria: SortCriteria, unique: Bool = false, descending: Bool = false) {
        appendOperation(.sort(criteria, unique: unique, descending: descending))
    }

    func performShuffle() {
        appendOperation(.shuffle)
    }

    func performSample(lines: Int) {
        appendOperation(.sample(lines: lines))
    }

    func performSetLineGroup(rangeStart: Int, rangeLen: Int, group: Int) {
        appendOperation(.setLineGroup(rangeStart: rangeStart, rangeLen: rangeLen, group: group))
    }

    /// Assigns every given row to `group` as a single operation-chain update.
    /// Must be used instead of calling `performSetLineGroup` once per row -
    /// each call to `appendOperation` triggers its own `replay()`, and
    /// `replay()` opens a brand-new `Corpus`/`LiveConcordance` (a fresh
    /// Manatee handle) - firing one per selected row let multiple overlapping
    /// handles hit the engine concurrently and crashed it.
    func performSetLineGroups(_ rangeStarts: [Int], group: Int) {
        guard !rangeStarts.isEmpty else { return }
        let ops = rangeStarts.map { ConcordanceOperation.setLineGroup(rangeStart: $0, rangeLen: 1, group: group) }
        setOperations(operations + ops)
    }

    /// Drops every `.setLineGroup` operation assigning `group` specifically
    /// (every other group's assignments are untouched) and replays - lines
    /// whose only assignment was to `group` revert to no group (Manatee's
    /// own default); a line reassigned to a different group afterward is
    /// unaffected, since its later operation is what's actually still in
    /// effect. Safe to filter by group number alone, ignoring position,
    /// because the toolbar disables sort/filter/shuffle/sample once any
    /// line group exists - every `.setLineGroup` operation in the chain
    /// therefore runs against the same, unchanging view order.
    func performClearLineGroup(_ group: Int) {
        setOperations(operations.filter {
            guard case .setLineGroup(_, _, let g) = $0 else { return true }
            return g != group
        })
    }

    /// Removes exactly one operation from the chain (e.g. a single sort or
    /// filter from the Operations popover) and replays the rest - more
    /// targeted than Undo, which can only unwind the most recent operation.
    /// `index` is into the full `operations` array, not a filtered display
    /// list, so callers showing a subset (see `OperationsPopoverController`)
    /// must track true indices themselves.
    func removeOperation(at index: Int) {
        guard operations.indices.contains(index) else { return }
        var newOperations = operations
        newOperations.remove(at: index)
        setOperations(newOperations)
    }

    private func appendOperation(_ op: ConcordanceOperation) {
        setOperations(operations + [op])
    }

    private func setOperations(_ newOperations: [ConcordanceOperation]) {
        let previous = operations
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.setOperations(previous)
        }
        operations = newOperations
        replay()
    }

    // MARK: - Query execution

    /// Chains onto any in-flight replay instead of letting two run
    /// concurrently - each `replay()` opens its own `Corpus`/`LiveConcordance`
    /// (a fresh Manatee handle), and the engine's thread-safety under
    /// concurrent access from separate handles is undocumented (see
    /// `LiveConcordance`'s doc comment). Two operations queued back-to-back
    /// before the first query resolves (e.g. `performSetLineGroups`, or any
    /// future rapid double-action) would otherwise fire concurrently.
    private var currentReplayTask: Task<Void, Never>?

    /// Bumped by every `replay()`. A replay that finds it isn't the latest
    /// any more (it was cancelled or overtaken while waiting its turn) drops
    /// its results and leaves the document's state to the newer one.
    private var replayGeneration = 0

    /// A query (or the operation chain after it) is running. Drives the
    /// window's "press ⌘. to cancel" hint and the Cancel Search menu item.
    private(set) var isSearching = false

    /// Awaited at the start of each search, once its turn has come. Tests
    /// hold a search open with it (a tiny corpus answers faster than a menu
    /// key press can be delivered); always nil in the app.
    var beforeSearchHook: (() async -> Void)?

    /// Aborts the running search: the engine stops (see
    /// `LiveConcordance.init(corpus:cql:)`) and the document shows no
    /// results and the status "Search cancelled." - the query and its
    /// operations stay, so pressing Return in the query bar searches again.
    /// Does nothing when no search is running.
    func cancelSearch() {
        guard isSearching else { return }
        currentReplayTask?.cancel()
    }

    /// Widens/narrows how many tokens of left/right context each KWIC line
    /// shows, in an already-open window - matches KonText's own live
    /// expand/narrow-context control. Unlike sort/filter/shuffle/sample,
    /// this is purely a display setting (mirrors `kwicAttr`): not part of
    /// the undoable `operations` chain, and doesn't require or invalidate
    /// line groups, since it can't change which hits exist or their order.
    func setContext(left: Int, right: Int) {
        leftContext = "-\(max(left, 0))"
        rightContext = "\(max(right, 0))"
        refetchDisplay()
    }

    /// What's actually sent to the engine for left/right context - see
    /// `ConcordanceViewMode`. `-1:s`/`1:s` are manatee-open's own
    /// Bonito/Sketch-Engine-style context-spec syntax for "expand to the
    /// enclosing `<s>` boundary" (confirmed in `concord/concctx.cc`),
    /// already supported end-to-end since `leftContext`/`rightContext`
    /// were free-form strings, not parsed integers, from the start.
    func setAttributeDisplay(inlineAttributes: [String], tooltipAttributes: [String]) {
        self.inlineAttributes = inlineAttributes
        self.tooltipAttributes = tooltipAttributes
        refetchDisplay()
    }

    /// Which structural attribute (e.g. "doc.title"), if any, to show as
    /// its own column on every row - same "pure display setting" status
    /// as `setContext`/`setAttributeDisplay`.
    func setStructuralAttributeDisplay(_ attribute: String?) {
        structuralAttributeToShow = attribute
        refetchDisplay()
    }

    /// Re-reads the lines of the existing result with the current context width, attribute
    /// display and region column - no new search. Nothing happens before the first search
    /// has produced a result (the next `replay()` will pick these settings up).
    private func refetchDisplay() {
        guard liveConcordance != nil else { return }
        let descendingSort = Self.descendingSort(in: operations)
        let previousReplay = currentReplayTask
        currentReplayTask = Task { @MainActor in
            await previousReplay?.value
            guard let live = liveConcordance else { return }
            do {
                let first = try await firstRows(live: live, descending: descendingSort)
                setRows(first.rows, count: first.count, source: first.source)
            } catch {
                status = "\(error)"
            }
            onResultsChanged?(false)
        }
    }

    private func replay() {
        guard !corpusName.trimmingCharacters(in: .whitespaces).isEmpty,
              !initialQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        replayGeneration += 1
        let generation = replayGeneration
        isSearching = true
        status = "Searching…"
        onResultsChanged?(true)
        let corpusName = corpusName
        let subcorpus = subcorpus
        let query = subcorpus?.restriction.apply(to: initialQuery) ?? initialQuery
        let operations = operations
        let descendingSort = Self.descendingSort(in: operations)
        let loadLimit = AppSettings.shared.maxConcordanceLines
        let previousReplay = currentReplayTask
        // A newer search replaces one still running (still one at a time: this
        // one waits for the cancelled one to let go of the engine).
        previousReplay?.cancel()
        currentReplayTask = Task { @MainActor in
            await previousReplay?.value
            // Overtaken while waiting: the newer replay covers this one.
            guard generation == replayGeneration else { return }
            await beforeSearchHook?()
            do {
                let corpus = try await engine.openCorpus(name: corpusName)
                let info = try await corpus.info()
                // A saved document (or an older one) may name an attribute this corpus doesn't have.
                textAttribute = info.defaultAttribute
                attributeNames = info.attributes
                if !info.attributes.contains(kwicAttr) { kwicAttr = info.defaultAttribute }
                inlineAttributes = inlineAttributes.filter(info.attributes.contains)
                tooltipAttributes = tooltipAttributes.filter(info.attributes.contains)
                let kwicAttr = kwicAttr
                let live = try await engine.openConcordance(query: query, in: corpus, limit: loadLimit)
                for op in operations {
                    try await op.apply(to: live)
                    try Task.checkCancellation()
                }
                let first = try await firstRows(live: live, descending: descendingSort)
                guard generation == replayGeneration else { return }
                setRows(first.rows, count: first.count, source: first.source)
                liveConcordance = live
                totalHits = await live.totalHits
                status = Self.statusLine(
                    shown: rowCount, total: totalHits, corpusTokens: info.sizeTokens, corpusName: corpusName,
                    subcorpus: subcorpus, operationLimit: await live.viewIsPartial ? loadLimit : nil,
                    sampled: operations.contains { if case .sample = $0 { return true } else { return false } })
            } catch {
                guard generation == replayGeneration else { return }
                setRows([], count: 0, source: nil)
                liveConcordance = nil
                totalHits = 0
                status = error is CancellationError ? "Search cancelled." : "\(error)"
            }
            isSearching = false
            onResultsChanged?(true)
        }
    }

    /// Hits in the whole corpus, loaded or not.
    private(set) var totalHits = 0

    /// "12 hits in the 38,181,322-token corpus UD", or for a big result "10,000 of 3,978,146 hits (the
    /// first ones; see Settings > Concordance) in ...".
    static func statusLine(shown: Int, total: Int, corpusTokens: Int, corpusName: String, subcorpus: Subcorpus?,
                           operationLimit: Int? = nil, sampled: Bool = false) -> String {
        let hits: String
        // An operation pando can't do on a result too big to hold in memory (several sort keys, line groups,
        // a sort of a sample) worked on the first hits only.
        var note = ""
        if total > shown, let operationLimit {
            hits = "\(shown.formatted()) of \(total.formatted()) hits"
            note = " (this works on the first \(operationLimit.formatted()) hits only: pando can\u{2019}t yet "
                + "sort by several keys or group lines on a result this large)"
        } else if total > shown, sampled {
            hits = "\(shown.formatted()) of \(total.formatted()) hits (a random sample)"
        } else if total > shown {
            hits = "\(shown.formatted()) of \(total.formatted()) hits (the first ones)"
        } else {
            hits = "\(shown.formatted()) hit\(shown == 1 ? "" : "s")"
        }
        let corpus = "the \(corpusTokens.formatted())-token corpus \u{201C}\(corpusName)\u{201D}"
        if let subcorpus {
            return "\(hits) in subcorpus \u{201C}\(subcorpus.name)\u{201D} of \(corpus)\(note)"
        }
        return "\(hits) in \(corpus)\(note)"
    }

    private static func descendingSort(in operations: [ConcordanceOperation]) -> Bool {
        operations.reversed().lazy.compactMap { op -> Bool? in
            if case .sort(_, _, let descending) = op { return descending }
            return nil
        }.first ?? false
    }

    // MARK: - Analysis (collocations, frequency distributions)

    enum AnalysisError: Error, CustomStringConvertible {
        case noResultsYet
        var description: String {
            switch self {
            case .noResultsYet: return "Run a query first."
            }
        }
    }

    /// Top collocates of the current query's hits - see `CollocationSpec`.
    /// Reflects whatever sort/filter/sample/line-groups are currently
    /// applied, since it runs against `liveConcordance` directly rather than
    /// replaying the operation chain again.
    func collocations(_ spec: CollocationSpec) async throws -> [CollocationItem] {
        guard let liveConcordance else { throw AnalysisError.noResultsYet }
        return try await liveConcordance.collocations(spec)
    }

    /// Where the current view's hits start across the corpus, in `bins`
    /// equal stretches (`DispersionView`). The axis is the corpus the query
    /// was run against, whole, even when the query ran in a subcorpus: hit
    /// positions are numbered in the parent, so the subcorpus's own size
    /// would put them off the end.
    func hitDistribution(bins: Int = 100) async throws -> HitDistribution {
        guard let liveConcordance else { throw AnalysisError.noResultsYet }
        let corpusSize = try await engine.openCorpus(name: corpusName).size
        // (With a subcorpus the plot still runs over the whole corpus's positions.)
        let counts = try await liveConcordance.hitHistogram(bins: bins, corpusSize: corpusSize)
        return HitDistribution(counts: counts, corpusSize: corpusSize)
    }

    /// Frequency distribution of the current query's hits - see
    /// `FrequencyCriterion`. Same "reflects the current view" behavior as
    /// `collocations(_:)`.
    func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int = 1) async throws -> [FrequencyItem] {
        guard let liveConcordance else { throw AnalysisError.noResultsYet }
        return try await liveConcordance.frequencyDistribution(criteria, minFrequency: minFrequency)
    }

    func structuralInfo(at rowID: Int) async throws -> [(structure: String, attribute: String, value: String)] {
        guard let liveConcordance else { throw AnalysisError.noResultsYet }
        guard rowID >= 0, rowID < rowCount else { return [] }
        return try await liveConcordance.structureInfo(forViewRow: viewIndex(forRow: rowID))
    }

    /// One hit's match plus much wider surrounding context than its table row shows
    /// (`AppSettings.defaultExtendedContextTokens` each side).
    func extendedContext(at rowID: Int) async throws -> (before: String, match: String, after: String) {
        guard let liveConcordance else { throw AnalysisError.noResultsYet }
        guard rowID >= 0, rowID < rowCount else { throw AnalysisError.noResultsYet }
        return try await liveConcordance.extendedContext(
            forViewRow: viewIndex(forRow: rowID), tokens: AppSettings.shared.defaultExtendedContextTokens)
    }

    struct ExtendedContextInfo {
        let corpusName: String
        let documentLabel: String?
        let sentenceLabel: String?

        var headerLines: [String] {
            var lines = ["Corpus: \(corpusName)"]
            if let documentLabel { lines.append("Document: \(documentLabel)") }
            if let sentenceLabel { lines.append("Sentence: \(sentenceLabel)") }
            return lines
        }
    }

    func extendedContextInfo(at rowID: Int) async throws -> ExtendedContextInfo {
        let info = try await structuralInfo(at: rowID)
        let documentLabel = structuralAttributeToShow.flatMap { attribute in
            info.first { "\($0.structure).\($0.attribute)" == attribute }
                .map { "\($0.attribute): \($0.value)" }
        }
        // The sentence's own id, when the corpus has one (`s.sent_id`, or the first `s` attribute).
        let sentence = info.first { $0.structure == "s" && $0.attribute == "sent_id" } ?? info.first { $0.structure == "s" }
        let sentenceLabel = sentence.map { "\($0.attribute): \($0.value)" }
        return ExtendedContextInfo(corpusName: corpusName, documentLabel: documentLabel, sentenceLabel: sentenceLabel)
    }

    // MARK: - Persistence (query + operation chain only, never the materialized rows)

    /// Version of the saved-document format. 1-2: the Manatee era (no longer readable: their queries and
    /// corpora don't exist any more); 3: pando, with `engine`, and the subcorpus as a saved restriction.
    /// A newer one is refused with a clear error rather than half-read.
    static let currentFormatVersion = 3

    /// Just enough to decide whether the rest can be read.
    private struct DocumentHeader: Decodable {
        var formatVersion: Int?
        var engine: String?
    }

    private struct DocumentState: Codable {
        var formatVersion: Int?
        var engine: String?
        var corpusName: String
        var subcorpus: Subcorpus?
        var initialQuery: String
        var leftContext: String
        var rightContext: String
        var kwicAttr: String
        // Optional so a document saved before these existed still decodes: a missing key becomes nil
        // for an Optional property under Codable's synthesized decoding, with no custom init needed.
        var inlineAttributes: [String]?
        var tooltipAttributes: [String]?
        var structuralAttributeToShow: String?
        var operations: [ConcordanceOperation]
    }

    override func data(ofType typeName: String) throws -> Data {
        let state = DocumentState(
            formatVersion: Self.currentFormatVersion, engine: engine.id,
            corpusName: corpusName, subcorpus: subcorpus, initialQuery: initialQuery,
            leftContext: leftContext, rightContext: rightContext, kwicAttr: kwicAttr,
            inlineAttributes: inlineAttributes, tooltipAttributes: tooltipAttributes,
            structuralAttributeToShow: structuralAttributeToShow, operations: operations)
        return try JSONEncoder().encode(state)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let header = try JSONDecoder().decode(DocumentHeader.self, from: data)
        if let version = header.formatVersion, version > Self.currentFormatVersion {
            throw DocumentFormatError.newerFormat(version)
        }
        // No engine key (version 1) or "manatee": made with the engine this app no longer has.
        guard let engineID = header.engine, engineID != "manatee", (header.formatVersion ?? 1) >= 3 else {
            throw DocumentFormatError.formerEngine
        }
        guard let engine = Engines.engine(withID: engineID) else {
            throw DocumentFormatError.unknownEngine(engineID)
        }
        let state = try JSONDecoder().decode(DocumentState.self, from: data)
        self.engine = engine
        corpusName = state.corpusName
        subcorpus = state.subcorpus
        initialQuery = state.initialQuery
        leftContext = state.leftContext
        rightContext = state.rightContext
        kwicAttr = state.kwicAttr
        inlineAttributes = state.inlineAttributes ?? []
        tooltipAttributes = state.tooltipAttributes ?? []
        structuralAttributeToShow = state.structuralAttributeToShow
        operations = state.operations
    }
}

struct HitDistribution: Equatable {
    let counts: [Int]
    let corpusSize: Int

    var hits: Int { counts.reduce(0, +) }
    var tokensPerBin: Int { max(corpusSize / max(counts.count, 1), 1) }

    /// One line for the window: how much is plotted, and how it's cut up.
    var summary: String {
        let perMillion = corpusSize > 0 ? Double(hits) / Double(corpusSize) * 1_000_000 : 0
        return "\(hits.formatted()) hit\(hits == 1 ? "" : "s") in a \(corpusSize.formatted())-token corpus "
            + "(\(perMillion.formatted(.number.precision(.fractionLength(0...2)))) per million), "
            + "in \(counts.count) parts of about \(tokensPerBin.formatted()) tokens"
    }
}
