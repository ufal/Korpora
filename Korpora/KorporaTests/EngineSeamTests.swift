import Cocoa
import ManateeKit
import Testing
@testable import Korpora

/// A scripted engine: no corpus on disk, no Manatee. Shows that
/// `ConcordanceDocument` only needs the `CorpusEngine` protocols
/// (docs/pando-analysis.md, Phase B).
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
        CorpusInfo(name: name, sizeTokens: 1_000, attributes: ["word"], structures: [])
    }
    func createSubcorpus(named: String, structure: String, query: String) async throws -> String { "/fake/\(named)" }
    func structuralAttributeValue(at position: Int, attribute: String) async throws -> String { "v\(position)" }
    func positionalAttributeRange(from: Int, to: Int, attribute: String) async throws -> String { "text" }
    func attributeValueCount(attribute: String) async throws -> Int { 0 }
    func attributeValues(attribute: String) async throws -> [String] { [] }
    func attributeValues(attribute: String, matching: String, ignoreCase: Bool, limit: Int) async throws -> [String] { [] }
    func topAttributeValues(attribute: String, limit: Int) async throws -> [(value: String, frequency: Int)] { [] }
    func topAttributeValues(attribute: String, matching: String, ignoreCase: Bool, limit: Int)
        async throws -> [(value: String, frequency: Int)] { [] }
    func openSubcorpusHandle(atPath path: String) async throws -> any CorpusHandle {
        recorder.add("subcorpus \(path)")
        return FakeCorpus(name: path, recorder: recorder)
    }
}

private actor FakeConcordance: ConcordanceHandle {
    let recorder: Recorder
    private var hits = 3
    init(recorder: Recorder) { self.recorder = recorder }
    var size: Int { get async { hits } }
    func hitHistogram(bins: Int, corpusSize: Int) async throws -> [Int] { [hits] + Array(repeating: 0, count: bins - 1) }
    func sort(_ criteria: SortCriteria, unique: Bool) async throws { recorder.add("sort") }
    func shuffle() async throws { recorder.add("shuffle") }
    func sample(lines: Int) async throws { recorder.add("sample \(lines)"); hits = min(hits, lines) }
    func filter(_ spec: PNFilterSpec) async throws { recorder.add("filter") }
    func setLineGroup(rangeStart: Int, rangeLen: Int, group: Int) async throws { recorder.add("group") }
    func linegroup(at lineIndex: Int) async -> Int { 0 }
    func deleteLineGroups(_ groups: [Int], invert: Bool) async throws {}
    func kwicLines(leftContext: String, rightContext: String, kwicAttr: String, secondaryAttributes: [String])
        async throws -> [KWICLine] {
        (0..<hits).map { i in
            KWICLine(leftTokens: [KWICToken(word: "left", secondaryAttributes: [:])],
                     kwicTokens: [KWICToken(word: "hit\(i)", secondaryAttributes: [:])],
                     rightTokens: [], position: 10 * i)
        }
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
    var id: String { "fake" }
    func openCorpus(name: String) async throws -> any CorpusHandle {
        recorder.add("open \(name)")
        return FakeCorpus(name: name, recorder: recorder)
    }
    func openConcordance(query: String, in corpus: any CorpusHandle) async throws -> any ConcordanceHandle {
        recorder.add("query \(query) in \(corpus.name)")
        return FakeConcordance(recorder: recorder)
    }
}

@MainActor @Suite(.serialized) struct EngineSeamTests {
    private let recorder = Recorder()
    private let defaults = UserDefaults(suiteName: "EngineSeamTests-\(UUID().uuidString)")!

    private func document() -> ConcordanceDocument {
        let document = ConcordanceDocument()
        document.engine = FakeEngine(recorder: recorder)
        document.corpusName = "fakecorp"
        document.historyDefaults = defaults
        return document
    }

    private func settle(_ document: ConcordanceDocument) async {
        for _ in 0..<2500 where document.isSearching { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func aQueryRunsThroughTheEngineAndFillsTheRows() async {
        let document = document()
        document.runQuery("[word=\"x\"]")
        await settle(document)
        #expect(recorder.all == ["open fakecorp", "query [word=\"x\"] in fakecorp"])
        #expect(document.rows.map { $0.line.kwic } == ["hit0", "hit1", "hit2"])
        #expect(document.status.hasPrefix("3 hits"), "\(document.status)")
        #expect(document.status.contains("1000-token") || document.status.contains("1,000-token"), "\(document.status)")
    }

    @Test func aSubcorpusIsOpenedThroughTheEngineToo() async {
        let document = document()
        document.subcorpusPath = "/fake/sub.subc"
        document.runQuery("[]")
        await settle(document)
        #expect(recorder.all.contains("subcorpus /fake/sub.subc"))
        #expect(recorder.all.last == "query [] in /fake/sub.subc")
    }

    @Test func operationsAndAnalysesGoToTheHandle() async throws {
        let document = document()
        document.runQuery("[]")
        await settle(document)
        let items = try await document.frequencyDistribution([FrequencyCriterion(attribute: "word")])
        #expect(items.map(\.word) == ["fake"])
        let collocates = try await document.collocations(CollocationSpec(attribute: "word"))
        #expect(collocates.first?.word == "fake")
        let distribution = try await document.hitDistribution(bins: 4)
        #expect(distribution.counts == [3, 0, 0, 0] && distribution.corpusSize == 1_000)
    }

    @Test func aFailingEngineShowsItsErrorInTheStatus() async {
        struct Broken: CorpusEngine {
            var id: String { "broken" }
            func openCorpus(name: String) async throws -> any CorpusHandle { throw ManateeError.failure("no such corpus") }
            func openConcordance(query: String, in corpus: any CorpusHandle) async throws -> any ConcordanceHandle {
                throw ManateeError.failure("unreachable")
            }
        }
        let document = document()
        document.engine = Broken()
        document.runQuery("[]")
        await settle(document)
        #expect(document.status.contains("no such corpus"), "\(document.status)")
        #expect(document.rows.isEmpty)
    }
}

/// The saved-document format carries a version and the engine id.
@MainActor @Suite struct DocumentFormatTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func state(_ extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "corpusName": "syn", "initialQuery": "[word=\"a\"]", "leftContext": "-10", "rightContext": "10",
            "kwicAttr": "word", "operations": [],
        ]
        object.merge(extra) { $1 }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func savingWritesTheVersionAndTheEngine() throws {
        let document = ConcordanceDocument()
        document.corpusName = "syn"
        let saved = try json(document.data(ofType: "corpconc"))
        #expect(saved["formatVersion"] as? Int == ConcordanceDocument.currentFormatVersion)
        #expect(saved["engine"] as? String == "manatee")
    }

    @Test func aVersionOneDocumentStillOpensAsManatee() throws {
        let document = ConcordanceDocument()
        try document.read(from: state(), ofType: "corpconc")
        #expect(document.corpusName == "syn" && document.initialQuery == "[word=\"a\"]")
        #expect(document.engine.id == "manatee")
    }

    @Test func roundTripKeepsTheContent() throws {
        let document = ConcordanceDocument()
        document.corpusName = "syn"
        document.subcorpusPath = "/x/y.subc"
        let copy = ConcordanceDocument()
        try copy.read(from: document.data(ofType: "corpconc"), ofType: "corpconc")
        #expect(copy.corpusName == "syn" && copy.subcorpusPath == "/x/y.subc" && copy.engine.id == "manatee")
    }

    @Test func aDocumentFromAnUnknownEngineIsRefusedClearly() throws {
        let document = ConcordanceDocument()
        #expect(throws: DocumentFormatError.self) {
            try document.read(from: state(["formatVersion": 2, "engine": "pando"]), ofType: "corpconc")
        }
        let message = (try? document.read(from: state(["engine": "pando"]), ofType: "corpconc")) == nil
        #expect(message)
        #expect(DocumentFormatError.unknownEngine("pando").localizedDescription.contains("pando"))
    }

    @Test func aNewerFormatIsRefusedClearly() throws {
        let document = ConcordanceDocument()
        #expect(throws: DocumentFormatError.self) {
            try document.read(from: state(["formatVersion": ConcordanceDocument.currentFormatVersion + 1]),
                              ofType: "corpconc")
        }
        #expect(DocumentFormatError.newerFormat(9).localizedDescription.contains("newer"))
    }
}
