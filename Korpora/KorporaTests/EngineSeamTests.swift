import Cocoa
import KorporaEngine
import Testing
@testable import Korpora

/// A scripted engine: no corpus on disk, no pando. Shows that `ConcordanceDocument` only needs
/// the `CorpusEngine` protocols (docs/pando-gui-plan.md), and pins what it does with their answers.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private actor FakeCorpus: CorpusHandle {
    nonisolated let name: String
    let recorder: Recorder
    init(name: String, recorder: Recorder) { self.name = name; self.recorder = recorder }
    var size: Int { get async throws { 1_000 } }
    func info() async throws -> CorpusInfo {
        CorpusInfo(name: name, sizeTokens: 1_000, attributes: ["form", "lemma"],
                   structures: [StructureInfo(name: "doc", attributes: ["title"])])
    }
    func attributeValueCount(attribute: String) async throws -> Int { 0 }
    func attributeValues(attribute: String) async throws -> [String] { [] }
    func attributeValues(attribute: String, matching: String, ignoreCase: Bool, limit: Int) async throws -> [String] { [] }
    func topAttributeValues(attribute: String, limit: Int) async throws -> [(value: String, frequency: Int)] { [] }
    func topAttributeValues(attribute: String, matching: String, ignoreCase: Bool, limit: Int)
        async throws -> [(value: String, frequency: Int)] { [] }
}

private actor FakeConcordance: ConcordanceHandle {
    let recorder: Recorder
    let total: Int
    /// What an operation works on: the first `loaded` hits (a result is every hit until then).
    private let loaded: Int
    private var hits: Int
    init(recorder: Recorder, total: Int = 3, loaded: Int = 3) {
        self.recorder = recorder; self.total = total; self.loaded = loaded; hits = total
    }
    private func operate() { hits = min(hits, loaded) }
    var size: Int { get async { hits } }
    var totalHits: Int { get async { total } }
    func hitHistogram(bins: Int, corpusSize: Int) async throws -> [Int] { [hits] + Array(repeating: 0, count: bins - 1) }
    func sort(_ criteria: SortCriteria, unique: Bool) async throws { operate(); recorder.add("sort") }
    func shuffle() async throws { operate(); recorder.add("shuffle") }
    func sample(lines: Int) async throws { operate(); recorder.add("sample \(lines)"); hits = min(hits, lines) }
    func setLineGroup(rangeStart: Int, rangeLen: Int, group: Int) async throws { operate(); recorder.add("group") }
    func linegroup(at lineIndex: Int) async -> Int { lineIndex == 1 ? 2 : 0 }
    func lineGroupCounts() async -> [Int: Int] { hits > 1 ? [2: 1] : [:] }
    func deleteLineGroups(_ groups: [Int], invert: Bool) async throws {}
    func kwicLines(range: Range<Int>, leftContext: String, rightContext: String, kwicAttr: String,
                   secondaryAttributes: [String]) async throws -> [KWICLine] {
        recorder.add("kwic \(leftContext) \(rightContext) \(kwicAttr)")
        return range.clamped(to: 0..<hits).map { i in
            KWICLine(leftTokens: [KWICToken(word: "left", secondaryAttributes: [:])],
                     kwicTokens: [KWICToken(word: "hit\(i)", secondaryAttributes: [:])],
                     rightTokens: [], position: 10 * i)
        }
    }
    func structureValues(attribute: String, range: Range<Int>) async throws -> [String] {
        recorder.add("structure \(attribute)")
        return range.clamped(to: 0..<hits).map { $0 == 0 ? "" : "Book \($0)" }
    }
    func structureInfo(forViewRow row: Int) async throws -> [(structure: String, attribute: String, value: String)] {
        [("doc", "title", "Book \(row)"), ("s", "sent_id", "s\(row)")]
    }
    func extendedContext(forViewRow row: Int, tokens: Int) async throws -> (before: String, match: String, after: String) {
        ("before \(row)", "hit", "after \(tokens)")
    }
    func collocations(_ spec: CollocationSpec) async throws -> [CollocationItem] {
        [CollocationItem(word: "fake", freq: 9, cnt: 3, score: 1.5)]
    }
    func frequencyDistribution(_ criteria: [FrequencyCriterion], minFrequency: Int) async throws -> [FrequencyItem] {
        [FrequencyItem(word: "fake", freq: 3)]
    }
}

private struct FakeEngine: CorpusEngine {
    let recorder: Recorder
    var total = 3
    var loaded = 3
    var id: String { "pando" }
    func openCorpus(name: String) async throws -> any CorpusHandle {
        recorder.add("open \(name)")
        return FakeCorpus(name: name, recorder: recorder)
    }
    func openConcordance(query: String, in corpus: any CorpusHandle, limit: Int) async throws -> any ConcordanceHandle {
        recorder.add("query \(query) limit \(limit)")
        return FakeConcordance(recorder: recorder, total: total, loaded: loaded)
    }
}

@MainActor @Suite(.serialized) struct EngineSeamTests {
    private let recorder = Recorder()
    private let defaults = UserDefaults(suiteName: "EngineSeamTests-\(UUID().uuidString)")!

    private func document(engine: (any CorpusEngine)? = nil) -> ConcordanceDocument {
        let document = ConcordanceDocument()
        document.engine = engine ?? FakeEngine(recorder: recorder)
        document.corpusName = "fakecorp"
        document.historyDefaults = defaults
        return document
    }

    private func settle(_ document: ConcordanceDocument) async {
        for _ in 0..<2500 where document.isSearching { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func aQueryRunsThroughTheEngineAndFillsTheRows() async {
        let document = document()
        document.runQuery("[form=\"x\"]")
        await settle(document)
        #expect(recorder.all.prefix(2) == ["open fakecorp", "query [form=\"x\"] limit \(AppSettings.shared.maxConcordanceLines)"])
        #expect(document.rows.map { $0.line.kwic } == ["hit0", "hit1", "hit2"])
        #expect(document.rows.map(\.group) == [0, 2, 0])
        #expect(document.status == "3 hits in the 1,000-token corpus \u{201C}fakecorp\u{201D}", "\(document.status)")
    }

    @Test func theCorpusDecidesWhichAttributeIsShown() async {
        let document = document()
        #expect(document.kwicAttr == "form")
        document.kwicAttr = "word"          // a saved document from the old engine's corpora
        document.runQuery("[]")
        await settle(document)
        #expect(document.kwicAttr == "form")
        #expect(document.textAttribute == "form")
        #expect(document.attributeNames == ["form", "lemma"])
        #expect(recorder.all.contains { $0.hasSuffix(" form") && $0.hasPrefix("kwic") })
    }

    @Test func aBigResultCanBeReadToItsEndAndSaysHowManyHitsThereAre() async {
        let document = document(engine: FakeEngine(recorder: recorder, total: 3_978_146, loaded: 100))
        document.runQuery("[]")
        await settle(document)
        #expect(document.totalHits == 3_978_146)
        #expect(document.rowCount == 3_978_146, "no cap: every hit is a row")
        #expect(document.rows.count == 2 * ConcordanceDocument.rowChunk, "only the first screens are loaded")
        #expect(document.status.hasPrefix("3,978,146 hits in the"), "\(document.status)")
    }

    @Test func rowsFarDownAreFetchedWhenTheTableAsksForThem() async {
        let document = document(engine: FakeEngine(recorder: recorder, total: 3_978_146, loaded: 100))
        document.runQuery("[]")
        await settle(document)
        var arrived: [Range<Int>] = []
        document.onRowsLoaded = { arrived.append($0) }
        #expect(document.row(at: 2_000_000) == nil, "not loaded yet; the fetch starts")
        for _ in 0..<500 where arrived.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(arrived.first?.contains(2_000_000) == true)
        #expect(document.row(at: 2_000_000)?.line.kwic == "hit2000000")
        #expect(document.row(at: 3_978_146) == nil)
        #expect(document.rows.count <= 4 * ConcordanceDocument.rowChunk)
    }

    @Test func aDescendingSortShowsTheViewBackwardsWindowByWindow() async {
        let document = document(engine: FakeEngine(recorder: recorder, total: 1_000, loaded: 1_000))
        document.runQuery("[]")
        await settle(document)
        document.performSort(SortCriteria(SortLevel(attribute: "form", anchor: .kwic)), descending: true)
        await settle(document)
        #expect(document.row(at: 0)?.line.kwic == "hit999")
        #expect(document.row(at: 0)?.viewIndex == 999)
        #expect(document.row(at: 5)?.line.kwic == "hit994")
    }

    @Test func sortingABigResultCoversItsFirstHitsAndTheStatusSaysWhy() async {
        let document = document(engine: FakeEngine(recorder: recorder, total: 3_978_146, loaded: 100))
        document.runQuery("[]")
        await settle(document)
        document.performShuffle()
        await settle(document)
        #expect(document.rowCount == 100)
        #expect(document.totalHits == 3_978_146)
        #expect(document.status.hasPrefix("100 of 3,978,146 hits in the"), "\(document.status)")
        #expect(document.status.contains("cover only the first \(AppSettings.shared.maxConcordanceLines.formatted()) hits"), "\(document.status)")
        #expect(document.status.contains("pando"), "\(document.status)")
    }

    @Test func theStatusLineWordsEachCase() {
        let sub = Subcorpus(name: "News", restriction: SubcorpusRestriction())
        #expect(ConcordanceDocument.statusLine(shown: 1, total: 1, corpusTokens: 12, corpusName: "C", subcorpus: nil)
                == "1 hit in the 12-token corpus \u{201C}C\u{201D}")
        #expect(ConcordanceDocument.statusLine(shown: 0, total: 0, corpusTokens: 12, corpusName: "C", subcorpus: nil)
                == "0 hits in the 12-token corpus \u{201C}C\u{201D}")
        #expect(ConcordanceDocument.statusLine(shown: 2, total: 2, corpusTokens: 1_234_567, corpusName: "C", subcorpus: sub)
                == "2 hits in subcorpus \u{201C}News\u{201D} of the 1,234,567-token corpus \u{201C}C\u{201D}")
    }

    @Test func aSubcorpusRestrictsTheQueryTheEngineSees() async {
        let document = document()
        document.subcorpus = Subcorpus(
            name: "Fiction", restriction: SubcorpusRestriction(structure: "doc", selections: [.init(attribute: "genre", values: ["fiction"])]))
        document.runQuery(#"[lemma="cat"]"#)
        await settle(document)
        #expect(recorder.all.contains { $0.hasPrefix(#"query [lemma="cat"] :: match.doc_genre = /fiction/ limit"#) }, "\(recorder.all)")
        #expect(document.initialQuery == #"[lemma="cat"]"#, "the query the user typed is what is kept and shown")
        #expect(document.corpusLabel == "fakecorp, subcorpus \u{201C}Fiction\u{201D}")
        #expect(document.status.contains("subcorpus \u{201C}Fiction\u{201D}"))
    }

    @Test func theRegionColumnComesFromOneBatchedLookup() async {
        let document = document()
        document.setStructuralAttributeDisplay("doc.title")
        document.runQuery("[]")
        await settle(document)
        #expect(recorder.all.filter { $0 == "structure doc.title" }.count == 1)
        #expect(document.rows.map(\.structuralAttributeValue) == [nil, "Book 1", "Book 2"], "empty values show nothing")
    }

    @Test func extendedContextAndHitInfoUseTheRowsPlaceInTheView() async throws {
        let document = document()
        document.runQuery("[]")
        await settle(document)
        let context = try await document.extendedContext(at: 2)
        #expect(context.before == "before 2")
        #expect(context.after == "after \(AppSettings.shared.defaultExtendedContextTokens)")
        let info = try await document.extendedContextInfo(at: 1)
        #expect(info.sentenceLabel == "sent_id: s1")
        #expect(info.corpusName == "fakecorp")
        let structure = try await document.structuralInfo(at: 1)
        #expect(structure.map(\.value) == ["Book 1", "s1"])
    }

    @Test func operationsAndAnalysesGoToTheHandle() async throws {
        let document = document()
        document.runQuery("[]")
        await settle(document)
        document.performShuffle()
        await settle(document)
        #expect(recorder.all.contains("shuffle"))
        let items = try await document.frequencyDistribution([FrequencyCriterion(attribute: "form")])
        #expect(items.map(\.word) == ["fake"])
        let collocates = try await document.collocations(CollocationSpec(attribute: "form"))
        #expect(collocates.first?.word == "fake")
        let distribution = try await document.hitDistribution(bins: 4)
        #expect(distribution.counts == [3, 0, 0, 0] && distribution.corpusSize == 1_000)
    }

    @Test func aFailingEngineShowsItsErrorInTheStatus() async {
        struct Broken: CorpusEngine {
            var id: String { "pando" }
            func openCorpus(name: String) async throws -> any CorpusHandle { throw PandoError.failure("no such corpus") }
            func openConcordance(query: String, in corpus: any CorpusHandle, limit: Int) async throws -> any ConcordanceHandle {
                throw PandoError.failure("unreachable")
            }
        }
        let document = document(engine: Broken())
        document.runQuery("[]")
        await settle(document)
        #expect(document.status.contains("no such corpus"), "\(document.status)")
        #expect(document.rows.isEmpty)
    }

    @Test func whenPandoCannotBeLoadedEverySearchSaysWhy() async {
        let document = document(engine: UnavailableEngine(reason: "libpando.dylib not found"))
        document.runQuery("[]")
        await settle(document)
        #expect(document.status.contains("libpando.dylib not found"), "\(document.status)")
    }
}

/// The saved-document format carries a version and the engine id; documents of the former engine
/// are refused clearly instead of half-read.
@MainActor @Suite struct DocumentFormatTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func state(_ extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "formatVersion": 3, "engine": "pando",
            "corpusName": "syn", "initialQuery": "[form=\"a\"]", "leftContext": "-10", "rightContext": "10",
            "kwicAttr": "form", "operations": [],
        ]
        object.merge(extra) { $1 }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func savingWritesTheVersionAndTheEngine() throws {
        let document = ConcordanceDocument()
        document.corpusName = "syn"
        let saved = try json(document.data(ofType: "corpconc"))
        #expect(saved["formatVersion"] as? Int == 3)
        #expect(saved["engine"] as? String == "pando")
        #expect(saved["subcorpus"] == nil)
    }

    @Test func roundTripKeepsTheContentIncludingTheSubcorpus() throws {
        let document = ConcordanceDocument()
        document.corpusName = "syn"
        document.initialQuery = "[lemma=\"x\"]"
        document.subcorpus = Subcorpus(
            name: "Fiction", restriction: SubcorpusRestriction(structure: "doc", selections: [.init(attribute: "genre", values: ["a", "b"])]))
        document.performSort(SortCriteria(SortLevel(attribute: "form", anchor: .left)))
        let copy = ConcordanceDocument()
        try copy.read(from: document.data(ofType: "corpconc"), ofType: "corpconc")
        #expect(copy.corpusName == "syn" && copy.initialQuery == "[lemma=\"x\"]")
        #expect(copy.subcorpus == document.subcorpus)
        #expect(copy.operations.count == 1)
        #expect(copy.engine.id == "pando")
    }

    @Test func aDocumentOfTheFormerEngineIsRefusedWithAnExplanation() throws {
        for extra: [String: Any] in [["formatVersion": 2, "engine": "manatee"], ["formatVersion": 1, "engine": NSNull()]] {
            let document = ConcordanceDocument()
            var thrown: Error?
            do { try document.read(from: state(extra), ofType: "corpconc") } catch { thrown = error }
            let error = try #require(thrown as? DocumentFormatError)
            #expect(error.localizedDescription.contains("former search engine"), "\(error.localizedDescription)")
        }
        // Version 1 files have neither key.
        let old = try JSONSerialization.data(withJSONObject: [
            "corpusName": "syn", "initialQuery": "[word=\"a\"]", "leftContext": "-10", "rightContext": "10",
            "kwicAttr": "word", "operations": [],
        ])
        #expect(throws: DocumentFormatError.self) { try ConcordanceDocument().read(from: old, ofType: "corpconc") }
    }

    @Test func aNewerFormatOrAnUnknownEngineIsRefusedClearly() throws {
        #expect(throws: DocumentFormatError.self) {
            try ConcordanceDocument().read(from: state(["formatVersion": 4]), ofType: "corpconc")
        }
        #expect(DocumentFormatError.newerFormat(9).localizedDescription.contains("newer"))
        #expect(throws: DocumentFormatError.self) {
            try ConcordanceDocument().read(from: state(["engine": "other"]), ofType: "corpconc")
        }
        #expect(DocumentFormatError.unknownEngine("other").localizedDescription.contains("other"))
    }
}
