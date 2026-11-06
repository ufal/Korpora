import Foundation
import XCTest
@testable import KorporaEngine

/// What the app does to a result: sort, sample, shuffle, group, plot, look up metadata.
/// The fixture has five hits of "cat" with different neighbours, in two documents.
final class PandoConcordanceOperationTests: XCTestCase {
    private var box: TestPando.Sandbox!
    private var engine: PandoEngine!
    private var corpus: (any CorpusHandle)!

    override func setUp() async throws {
        box = try TestPando.Sandbox()
        engine = try await TestPando.buildCorpus("Cats", conllu: TestPando.catsConllu, in: box)
        corpus = try await engine.openCorpus(name: "Cats")
    }

    private func cats(limit: Int = 100) async throws -> any ConcordanceHandle {
        try await engine.openConcordance(query: #"[lemma="cat"]"#, in: corpus, limit: limit)
    }

    /// "left | hit | right" for each line, to read an order at a glance.
    private func order(_ live: any ConcordanceHandle) async throws -> [String] {
        try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
            .map { "\($0.left)|\($0.kwic)|\($0.right)" }
    }

    // Hits in corpus order, one token of context each side. The fifth is the one-word sentence s5,
    // whose left neighbour is the last word of s4.
    private let corpusOrder = ["big|cat|sleeps", "small|cat|eats", "one|cat|runs", "my|cat|Sleeps", "Sleeps|cat|"]

    func testLoadsHitsInCorpusOrderWithCounts() async throws {
        let live = try await cats()
        let size = await live.size
        let total = await live.totalHits
        XCTAssertEqual(size, 5)
        XCTAssertEqual(total, 5)
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(lines.map(\.position), [2, 6, 9, 12, 14])
        XCTAssertEqual(lines.map(\.right), ["sleeps", "eats", "runs", "Sleeps", ""])
    }

    func testWithoutAnOperationEveryHitCanBeReadWindowByWindow() async throws {
        let live = try await cats(limit: 3)
        let sizeBefore = await live.size
        XCTAssertEqual(sizeBefore, 5, "the limit is for operations; reading a result needs none")
        let window = try await live.kwicLines(range: 1..<4, leftContext: "-1", rightContext: "1", kwicAttr: "form",
                                              secondaryAttributes: [])
        XCTAssertEqual(window.map(\.position), [6, 9, 12])
        XCTAssertEqual(window.map { "\($0.left)|\($0.kwic)|\($0.right)" }, Array(corpusOrder[1..<4]))
        let past = try await live.kwicLines(range: 3..<50, leftContext: "-1", rightContext: "1", kwicAttr: "form",
                                            secondaryAttributes: [])
        XCTAssertEqual(past.map(\.position), [12, 14], "a window past the end is cut to the result")
        let total = await live.totalHits
        XCTAssertEqual(total, 5)
    }

    // MARK: A result larger than the limit: pando orders it, on all its hits

    /// The same five hits, with a limit of 2: "5 hits is a big result".
    private func big() async throws -> any ConcordanceHandle { try await cats(limit: 2) }

    func testPandoSortsABigResultOnAllItsHits() async throws {
        let live = try await big()
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .right, span: 1, caseInsensitive: true)))
        let size = await live.size
        XCTAssertEqual(size, 5, "every hit, not the first two")
        let partial = await live.viewIsPartial
        XCTAssertFalse(partial)
        let rights = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
            .map(\.right)
        XCTAssertEqual(rights, ["", "eats", "runs", "sleeps", "Sleeps"], "the order the in-memory sort gives")
        let window = try await live.kwicLines(range: 1..<3, leftContext: "-1", rightContext: "1", kwicAttr: "form",
                                              secondaryAttributes: [])
        XCTAssertEqual(window.map(\.right), ["eats", "runs"], "a window of the sorted result")
    }

    func testPandoSortsByTheWordToTheLeft() async throws {
        let live = try await big()
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .left, span: 1)))
        let lefts = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
            .map(\.left)
        // pando compares by code point (capitals first), where the in-memory sort of a small result uses the
        // locale's alphabetical order ("big, my, one, Sleeps, small"). %c folds case but is no collation.
        XCTAssertEqual(lefts, ["Sleeps", "big", "my", "one", "small"])
    }

    func testASortedBigResultKnowsItsRegionsAndWideContext() async throws {
        let live = try await big()
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .right, span: 1, caseInsensitive: true)))
        let sorted = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        let reference = try await cats()
        try await reference.sort(SortCriteria(SortLevel(attribute: "form", anchor: .right, span: 1, caseInsensitive: true)))
        let expectedGenres = try await reference.structureValues(attribute: "doc.genre")
        let genres = try await live.structureValues(attribute: "doc.genre")
        XCTAssertEqual(genres, expectedGenres)
        let context = try await live.extendedContext(forViewRow: 1, tokens: 2)
        XCTAssertEqual(context.match, sorted[1].kwic)
        let info = try await live.structureInfo(forViewRow: 1)
        let expectedInfo = try await reference.structureInfo(forViewRow: 1)
        XCTAssertEqual(info.map { "\($0.structure).\($0.attribute)=\($0.value)" },
                       expectedInfo.map { "\($0.structure).\($0.attribute)=\($0.value)" })
    }

    func testPandoShufflesABigResultAndKeepsTheOrderBetweenWindows() async throws {
        let live = try await big()
        try await live.shuffle()
        let size = await live.size
        XCTAssertEqual(size, 5)
        let all = try await order(live)
        XCTAssertEqual(Set(all), Set(corpusOrder), "the same hits")
        let again = try await order(live)
        XCTAssertEqual(again, all, "one seed: the same order every time")
        let tail = try await live.kwicLines(range: 3..<5, leftContext: "-1", rightContext: "1", kwicAttr: "form",
                                            secondaryAttributes: [])
        XCTAssertEqual(tail.map { "\($0.left)|\($0.kwic)|\($0.right)" }, Array(all[3..<5]), "windows agree with the whole")
        do {
            _ = try await live.structureValues(attribute: "doc.genre", range: 0..<5)
            XCTFail("pando's hit pages carry no region values")
        } catch is PandoError {}
        do {
            _ = try await live.structureInfo(forViewRow: 0)
            XCTFail("the document of a shuffled hit of a big result can't be looked up")
        } catch { }
        let context = try await live.extendedContext(forViewRow: 2, tokens: 2)
        XCTAssertEqual(context.match, "cat")
    }

    func testPandoSamplesABigResult() async throws {
        let live = try await big()
        try await live.sample(lines: 3)
        let size = await live.size
        XCTAssertEqual(size, 3)
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.position), lines.map(\.position).sorted(), "a sample keeps corpus order")
        let again = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(again.map(\.position), lines.map(\.position), "one seed: the same hits")
        let total = await live.totalHits
        XCTAssertEqual(total, 5)
    }

    func testWhatPandoCantDoWorksOnTheFirstHitsOfTheCurrentOrder() async throws {
        let live = try await big()
        // Two sort keys: pando sorts one.
        try await live.sort(SortCriteria(levels: [
            SortLevel(attribute: "form", anchor: .right, span: 1, caseInsensitive: true),
            SortLevel(attribute: "form", anchor: .left, span: 1),
        ]))
        let size = await live.size
        XCTAssertEqual(size, 2, "in memory, over the first two hits")
        let partial = await live.viewIsPartial
        XCTAssertTrue(partial)
        let total = await live.totalHits
        XCTAssertEqual(total, 5)
        // Line groups too, and after a shuffle they take the shuffled order's first hits.
        let grouped = try await big()
        try await grouped.shuffle()
        let shuffled = try await order(grouped)
        try await grouped.setLineGroup(rangeStart: 0, rangeLen: 1, group: 1)
        let afterGroup = try await order(grouped)
        XCTAssertEqual(afterGroup, Array(shuffled.prefix(2)))
        let groupCounts = await grouped.lineGroupCounts()
        XCTAssertEqual(groupCounts, [1: 1])
    }

    func testASmallResultIsSortedAndShuffledInMemoryWithEveryOption() async throws {
        let live = try await cats()
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .kwic, reverse: true)), unique: false)
        let size = await live.size
        XCTAssertEqual(size, 5)
        let partial = await live.viewIsPartial
        XCTAssertFalse(partial)
    }

    // MARK: Sentence view

    func testSentenceContextStopsAtTheSentenceBoundary() async throws {
        let live = try await cats()
        let lines = try await live.kwicLines(range: 0..<5, leftContext: "-1:s", rightContext: "1:s", kwicAttr: "form",
                                             secondaryAttributes: [])
        // Fifth hit: the one-word sentence s5, whose left neighbour in a token window is the end of s4.
        XCTAssertEqual(lines.map { "\($0.left)|\($0.kwic)|\($0.right)" },
                       ["the big|cat|sleeps", "a small|cat|eats", "one|cat|runs", "my|cat|Sleeps", "|cat|"])
        let kwic = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(kwic.last?.left, "Sleeps", "back to a token window gives the neighbour again")
    }

    func testSentenceContextAlsoOfSortedAndBigResults() async throws {
        let live = try await cats()
        try await live.shuffle()
        let loaded = try await live.kwicLines(leftContext: "-1:s", rightContext: "1:s", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(Set(loaded.map { "\($0.left)|\($0.kwic)|\($0.right)" }),
                       ["the big|cat|sleeps", "a small|cat|eats", "one|cat|runs", "my|cat|Sleeps", "|cat|"], "in memory")
        let big = try await cats(limit: 2)
        try await big.sort(SortCriteria(SortLevel(attribute: "form", anchor: .right, span: 1, caseInsensitive: true)))
        let sorted = try await big.kwicLines(leftContext: "-1:s", rightContext: "1:s", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(sorted.map(\.right), ["", "eats", "runs", "sleeps", "Sleeps"], "sorted by pando, sentence context")
        XCTAssertEqual(sorted.first?.left, "")
    }

    func testRegionValuesAndGroupsOfAWindow() async throws {
        let live = try await cats()
        let genres = try await live.structureValues(attribute: "doc.genre", range: 2..<4)
        XCTAssertEqual(genres.count, 2)
        let groups = await live.lineGroupCounts()
        XCTAssertTrue(groups.isEmpty)
        try await live.setLineGroup(rangeStart: 0, rangeLen: 2, group: 3)
        let counts = await live.lineGroupCounts()
        XCTAssertEqual(counts, [3: 2])
    }

    func testAQueryWithNoHits() async throws {
        let live = try await engine.openConcordance(query: #"[lemma="zebra"]"#, in: corpus)
        let size = await live.size
        XCTAssertEqual(size, 0)
        let lines = try await live.kwicLines()
        XCTAssertEqual(lines.count, 0)
        try await live.shuffle()
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .left)))
        let histogram = try await live.hitHistogram(bins: 3, corpusSize: 15)
        XCTAssertEqual(histogram, [0, 0, 0])
    }

    // MARK: Sorting

    func testSortByTheWordToTheLeftNearestFirst() async throws {
        let live = try await cats()
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .left, span: 1)))
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        // Locale order, case-sensitive: "Sleeps" (the hit of s5; its left neighbour ends s4) sorts before "small".
        XCTAssertEqual(lines.map(\.left), ["big", "my", "one", "Sleeps", "small"])
    }

    func testSortByTheWordToTheRightAndCaseInsensitively() async throws {
        let live = try await cats()
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .right, span: 1, caseInsensitive: true)))
        // "" (end of corpus), eats, runs, then sleeps and Sleeps tie and keep corpus order.
        let rights = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
            .map(\.right)
        XCTAssertEqual(rights, ["", "eats", "runs", "sleeps", "Sleeps"])
    }

    func testSortByTheHitsOwnAttributeUsesTheMatchToken() async throws {
        let live = try await engine.openConcordance(query: #"[upos="NOUN" | upos="VERB"]"#, in: corpus)
        try await live.sort(SortCriteria(SortLevel(attribute: "lemma", anchor: .kwic)))
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "lemma", secondaryAttributes: [])
        let lemmas = lines.map(\.kwic)
        XCTAssertEqual(lemmas, lemmas.sorted { $0.compare($1, locale: .current) == .orderedAscending })
    }

    func testRetrogradeSortsBySuffix() async throws {
        let live = try await engine.openConcordance(query: #"[upos="VERB"]"#, in: corpus)
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .kwic, reverse: true)))
        let words = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: []).map(\.kwic)
        // Compared by reversed spelling: "snur" (runs) < "speels" (sleeps) < "speelS" (Sleeps) < "stae" (eats).
        XCTAssertEqual(words, ["runs", "sleeps", "Sleeps", "eats"])
    }

    func testMultiLevelSortAndUnique() async throws {
        let live = try await cats()
        // Level 1: first word to the right (case-insensitive: sleeps = Sleeps), level 2: first word to the left.
        try await live.sort(SortCriteria(levels: [
            SortLevel(attribute: "form", anchor: .right, span: 1, caseInsensitive: true),
            SortLevel(attribute: "form", anchor: .left, span: 1),
        ]))
        let rows = try await order(live)
        XCTAssertEqual(rows.last, "my|cat|Sleeps", "'my' sorts after 'big' on the second level")
        // Unique keeps one line per distinct key.
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .kwic)), unique: true)
        let size = await live.size
        XCTAssertEqual(size, 1, "all five hits are the word 'cat'")
    }

    func testSortingByAnAttributeOfTheContextWordsIsRefusedClearly() async throws {
        let live = try await cats()
        do {
            try await live.sort(SortCriteria(SortLevel(attribute: "lemma", anchor: .left)))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("lemma"), "\(error)")
        }
        let rows = try await order(live)
        XCTAssertEqual(rows, corpusOrder, "a refused sort changes nothing")
    }

    // MARK: Shuffle, sample, line groups

    func testShuffleKeepsTheSameHits() async throws {
        let live = try await cats()
        var seen = Set<[String]>()
        for _ in 0..<12 {
            try await live.shuffle()
            let rows = try await order(live)
            XCTAssertEqual(rows.sorted(), corpusOrder.sorted())
            seen.insert(rows)
        }
        XCTAssertGreaterThan(seen.count, 1, "twelve shuffles of five hits gave one order")
    }

    func testSampleKeepsARandomSubsetInViewOrder() async throws {
        let live = try await cats()
        try await live.sample(lines: 3)
        let size = await live.size
        XCTAssertEqual(size, 3)
        let rows = try await order(live)
        XCTAssertEqual(Set(rows).count, 3)
        // In the order they had.
        let indices = rows.map { corpusOrder.firstIndex(of: $0)! }
        XCTAssertEqual(indices, indices.sorted())
        // A sample larger than the view changes nothing.
        try await live.sample(lines: 10)
        let after = await live.size
        XCTAssertEqual(after, 3)
    }

    func testLineGroupsFollowTheLinesThroughSorting() async throws {
        let live = try await cats()
        try await live.setLineGroup(rangeStart: 1, rangeLen: 2, group: 3)   // small, one
        let before = await [live.linegroup(at: 0), live.linegroup(at: 1), live.linegroup(at: 2), live.linegroup(at: 3)]
        XCTAssertEqual(before, [0, 3, 3, 0])
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .left)))
        // Sorted by left word: big, my, one, Sleeps, small -> the groups stay with "one" and "small".
        var groups: [Int] = []
        for row in 0..<5 { groups.append(await live.linegroup(at: row)) }
        XCTAssertEqual(groups, [0, 0, 3, 0, 3])
        let outside = await live.linegroup(at: 99)
        XCTAssertEqual(outside, 0)
    }

    func testDeletingLineGroupsKeepsOrDropsThem() async throws {
        let live = try await cats()
        try await live.setLineGroup(rangeStart: 0, rangeLen: 2, group: 1)
        try await live.setLineGroup(rangeStart: 2, rangeLen: 1, group: 2)
        try await live.deleteLineGroups([1], invert: false)
        var size = await live.size
        XCTAssertEqual(size, 3, "group 1 (two lines) removed")
        try await live.deleteLineGroups([2], invert: true)
        size = await live.size
        XCTAssertEqual(size, 1, "kept only group 2")
        // Ungrouping a line makes it group 0 again.
        try await live.setLineGroup(rangeStart: 0, rangeLen: 1, group: 0)
        let group = await live.linegroup(at: 0)
        XCTAssertEqual(group, 0)
    }

    func testViewSurvivesAWiderContextBeingLoadedLater() async throws {
        let live = try await cats()
        try await live.setLineGroup(rangeStart: 0, rangeLen: 1, group: 4)
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .left)))
        let first = try await order(live)
        // Asking for more context than was loaded reloads the lines; the order and groups stay.
        let wide = try await live.kwicLines(leftContext: "-40", rightContext: "40", kwicAttr: "form", secondaryAttributes: [])
        let narrow = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(wide.map(\.position), narrow.map(\.position))
        let again = try await order(live)
        XCTAssertEqual(again, first)
        var groups: [Int] = []
        for row in 0..<5 { groups.append(await live.linegroup(at: row)) }
        XCTAssertEqual(groups.filter { $0 == 4 }.count, 1)
    }

    // MARK: Positions and metadata

    func testHitHistogramOfLoadedAndOfUnloadedHits() async throws {
        // 15 tokens, hits at 2, 6, 9, 12, 14.
        let all = try await cats()
        _ = try await all.kwicLines()
        let loaded = try await all.hitHistogram(bins: 3, corpusSize: 15)
        XCTAssertEqual(loaded, [1, 2, 2])     // bins of 5 tokens: [2] [6,9] [12,14]
        let capped = try await cats(limit: 2)
        _ = try await capped.kwicLines()
        let paged = try await capped.hitHistogram(bins: 3, corpusSize: 15)
        XCTAssertEqual(paged, loaded, "a capped result still plots every hit")
        // The loaded one follows the view: a sample plots fewer.
        try await all.sample(lines: 2)
        let sampled = try await all.hitHistogram(bins: 3, corpusSize: 15)
        XCTAssertEqual(sampled.reduce(0, +), 2)
    }

    func testRegionValuesFollowTheViewOrder() async throws {
        let live = try await cats()
        let genres = try await live.structureValues(attribute: "doc.genre")
        XCTAssertEqual(genres, ["fiction", "fiction", "fiction", "news report", "news report"])
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .left)))
        // Sorted by left word: big (s1, fiction), my (s4, news), one (s3, fiction), Sleeps (s5, news), small (s2, fiction)
        let sorted = try await live.structureValues(attribute: "doc.genre")
        XCTAssertEqual(sorted, ["fiction", "news report", "fiction", "news report", "fiction"])
        let titles = try await live.structureValues(attribute: "doc.title")
        XCTAssertEqual(titles, ["Alpha book", "Beta", "Alpha book", "Beta", "Alpha book"])
    }

    func testStructureInfoOfOneHit() async throws {
        let live = try await cats()
        let info = try await live.structureInfo(forViewRow: 3)   // "my cat Sleeps", document d2
        let byName = Dictionary(uniqueKeysWithValues: info.map { ("\($0.structure).\($0.attribute)", $0.value) })
        XCTAssertEqual(byName["doc.genre"], "news report")
        XCTAssertEqual(byName["doc.title"], "Beta")
        XCTAssertEqual(byName["doc.id"], "d2")
        XCTAssertEqual(byName["s.sent_id"], "s4")
        let none = try await live.structureInfo(forViewRow: 50)
        XCTAssertTrue(none.isEmpty)
    }

    func testExtendedContextOfTheRowInView() async throws {
        let live = try await cats()
        try await live.sort(SortCriteria(SortLevel(attribute: "form", anchor: .left)))
        // Row 0 after the sort is "big cat sleeps".
        let context = try await live.extendedContext(forViewRow: 0, tokens: 3)
        XCTAssertEqual(context.match, "cat")
        XCTAssertEqual(context.before, "the big")
        XCTAssertEqual(context.after, "sleeps a small")
        do {
            _ = try await live.extendedContext(forViewRow: 9, tokens: 3)
            XCTFail("expected an error")
        } catch {}
    }

    func testRestrictionsApplyToTheLoadedHits() async throws {
        let restricted = SubcorpusRestriction(structure: "doc", selections: [.init(attribute: "genre", values: ["news report"])])
        let live = try await engine.openConcordance(query: restricted.apply(to: #"[lemma="cat"]"#), in: corpus)
        let lines = try await live.kwicLines(leftContext: "-1", rightContext: "1", kwicAttr: "form", secondaryAttributes: [])
        XCTAssertEqual(lines.map(\.position), [12, 14])
    }
}
