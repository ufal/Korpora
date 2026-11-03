import Foundation
import XCTest
@testable import KorporaEngine

final class SubcorpusTests: XCTestCase {
    private func restriction(_ pairs: [(String, [String])], structure: String = "doc") -> SubcorpusRestriction {
        SubcorpusRestriction(structure: structure, selections: pairs.map { .init(attribute: $0.0, values: $0.1) })
    }

    func testFilterForOneValueSeveralValuesAndSeveralAttributes() {
        XCTAssertEqual(restriction([("genre", ["fiction"])]).filter, "match.doc_genre = /fiction/")
        XCTAssertEqual(restriction([("genre", ["fiction", "essay"])]).filter, "match.doc_genre = /fiction|essay/")
        XCTAssertEqual(restriction([("genre", ["a", "b"]), ("year", ["2007"])]).filter,
                       "match.doc_genre = /a|b/ & match.doc_year = /2007/")
        XCTAssertEqual(restriction([("genre", ["x"])], structure: "text").filter, "match.text_genre = /x/")
    }

    func testEmptySelectionsMeanNoFilter() {
        XCTAssertTrue(restriction([]).isEmpty)
        XCTAssertTrue(restriction([("genre", [])]).isEmpty)
        XCTAssertEqual(restriction([("genre", [])]).apply(to: "[]"), "[]")
        XCTAssertEqual(restriction([("genre", []), ("year", ["2007"])]).filter, "match.doc_year = /2007/")
    }

    func testValuesAreEscapedSoTheyMatchLiterally() {
        XCTAssertEqual(SubcorpusRestriction.regexEscaped("Smith (Jr.)"), #"Smith \(Jr\.\)"#)
        XCTAssertEqual(SubcorpusRestriction.regexEscaped("a/b|c"), #"a\/b\|c"#)
        XCTAssertEqual(SubcorpusRestriction.regexEscaped("NOV: próza"), "NOV: próza")
        XCTAssertEqual(restriction([("title", ["A/B"])]).filter, #"match.doc_title = /A\/B/"#)
        XCTAssertEqual(SubcorpusRestriction.containsPattern("a.b"), #".*a\.b.*"#)
    }

    func testAppliedToAQueryItAddsOrExtendsTheGlobalFilter() {
        let r = restriction([("genre", ["fiction"])])
        XCTAssertEqual(r.apply(to: #"[lemma="cat"]"#), #"[lemma="cat"] :: match.doc_genre = /fiction/"#)
        XCTAssertEqual(r.apply(to: "  [lemma=\"cat\"]  \n"), #"[lemma="cat"] :: match.doc_genre = /fiction/"#)
        XCTAssertEqual(r.apply(to: #"a:[lemma="the"] [] b:[lemma="the"] :: a.form = b.form"#),
                       #"a:[lemma="the"] [] b:[lemma="the"] :: a.form = b.form & match.doc_genre = /fiction/"#)
    }

    func testColonsInsideStringsAreNotAGlobalFilter() {
        XCTAssertFalse(SubcorpusRestriction.hasGlobalFilter(#"[form="::"]"#))
        XCTAssertFalse(SubcorpusRestriction.hasGlobalFilter(#"[form=/a::b/]"#))
        XCTAssertFalse(SubcorpusRestriction.hasGlobalFilter("[upos=\"X\"] within s"))
        XCTAssertTrue(SubcorpusRestriction.hasGlobalFilter(#"[lemma="a"] :: a.x = "y""#))
        let r = restriction([("genre", ["g"])])
        XCTAssertEqual(r.apply(to: #"[form="::"]"#), #"[form="::"] :: match.doc_genre = /g/"#)
    }

    func testRestrictionsCodableRoundTrip() throws {
        let s = Subcorpus(name: "Fiction 2007", restriction: restriction([("genre", ["fiction"]), ("year", ["2007"])]))
        let decoded = try JSONDecoder().decode(Subcorpus.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }

    // MARK: Saved subcorpora

    func testSaveListReplaceAndDelete() throws {
        let box = try TestPando.Sandbox()
        _ = box
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "syn"), [])
        let a = Subcorpus(name: "B subcorpus", restriction: restriction([("genre", ["x"])]))
        let b = Subcorpus(name: "A subcorpus", restriction: restriction([("genre", ["y"])]))
        try SubcorpusLibrary.save(a, in: "syn")
        try SubcorpusLibrary.save(b, in: "syn")
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "syn").map(\.name), ["A subcorpus", "B subcorpus"])

        var changed = a
        changed.restriction = restriction([("genre", ["z"])])
        try SubcorpusLibrary.save(changed, in: "syn")
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "syn").count, 2)
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "syn").last?.restriction.filter, "match.doc_genre = /z/")

        try SubcorpusLibrary.delete(named: "A subcorpus", in: "syn")
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "syn").map(\.name), ["B subcorpus"])
        SubcorpusLibrary.deleteAll(of: "syn")
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "syn"), [])
    }

    func testSubcorporaArePerCorpusAndSurviveOddNames() throws {
        let box = try TestPando.Sandbox()
        _ = box
        try SubcorpusLibrary.save(Subcorpus(name: "x", restriction: restriction([])), in: "one")
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "two"), [])
        try SubcorpusLibrary.save(Subcorpus(name: "y", restriction: restriction([])), in: "a/b")
        XCTAssertEqual(SubcorpusLibrary.subcorpora(of: "a/b").map(\.name), ["y"])
    }

    // MARK: Against real pando

    func testRestrictionsChangeTheHitsOfAPandoQuery() async throws {
        let library = try TestPando.library()
        guard let path = TestPando.libraryPath else { return }
        let tool = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pando-index")
        let box = try TestPando.Sandbox()
        // Two documents with different genres.
        let input = box.root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let text = """
            # newdoc id = d1
            # meta::genre = fiction
            # meta::title = The first book
            # sent_id = a
            1\tcats\tcat\tNOUN\t_\t_\t0\troot\t_\t_

            # newdoc id = d2
            # meta::genre = news report
            # meta::title = The second
            # sent_id = b
            1\tcats\tcat\tNOUN\t_\t_\t0\troot\t_\t_

            # sent_id = c
            1\tdogs\tdog\tNOUN\t_\t_\t0\troot\t_\t_


            """
        try text.write(to: input.appendingPathComponent("t.conllu"), atomically: true, encoding: .utf8)
        _ = try await CorpusImporter.importCorpus(name: "two docs", inputs: [input], tool: tool)
        let engine = PandoEngine(library: library)
        let corpus = try await engine.openCorpus(name: "two docs")

        func hits(_ query: String) async throws -> Int {
            try await engine.openConcordance(query: query, in: corpus).size
        }
        let all = try await hits(#"[lemma="cat"]"#)
        XCTAssertEqual(all, 2)
        let fiction = restriction([("genre", ["fiction"])]).apply(to: #"[lemma="cat"]"#)
        let inFiction = try await hits(fiction)
        XCTAssertEqual(inFiction, 1)
        // Values with spaces, and alternatives.
        let news = try await hits(restriction([("genre", ["news report"])]).apply(to: #"[lemma="cat"]"#))
        XCTAssertEqual(news, 1)
        let either = try await hits(restriction([("genre", ["fiction", "news report"])]).apply(to: #"[lemma="cat"]"#))
        XCTAssertEqual(either, 2)
        let none = try await hits(restriction([("genre", ["poetry"])]).apply(to: #"[lemma="cat"]"#))
        XCTAssertEqual(none, 0)
        // Combined with a query that already has a global filter.
        let combined = restriction([("genre", ["fiction"])]).apply(to: #"a:[lemma="cat"] :: a.form = "cats""#)
        let inBoth = try await hits(combined)
        XCTAssertEqual(inBoth, 1)
    }
}
