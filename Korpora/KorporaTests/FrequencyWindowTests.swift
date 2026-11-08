import AppKit
import Foundation
import Testing
import KorporaEngine
@testable import Korpora

@MainActor @Suite struct FrequencyWindowTests {
    private let fields = [FrequencyField(node: "a", attribute: "lemma"), FrequencyField(node: "b", attribute: "upos")]

    private func table(cut: Bool = false, total: Int = 11) -> FrequencyTable {
        FrequencyTable(fields: fields, rows: [
            FrequencyRow(values: ["give", "NOUN"], count: 6, percent: 54.5, perMillion: 6),
            FrequencyRow(values: ["take", "PRON"], count: 3, percent: 27.3, perMillion: 3),
            FrequencyRow(values: ["give", "PRON"], count: 2, percent: 18.2, perMillion: 2),
        ], totalMatches: total, isCut: cut)
    }

    private func controller(_ table: FrequencyTable, keys: [FrequencySortKey] = []) throws -> FrequencyViewController {
        let window = FrequencyWindowController(table: table, sortKeys: keys, nodes: QueryNodes("[] > []"))
        return try #require(window.window?.contentViewController as? FrequencyViewController)
    }

    @Test func hasAColumnForEachFieldThenCountPercentAndPerMillion() throws {
        let c = try controller(table())
        _ = c.view
        #expect(c.tableView.tableColumns.map(\.identifier.rawValue) == ["field0", "field1", "count", "percent", "perMillion"])
        #expect(c.tableView.tableColumns[0].headerCell.stringValue == "\u{25CF} a lemma", "the node's colour dot, its name, the attribute")
        #expect(c.tableView.tableColumns[2].title == "Freq")
    }

    @Test func noPerMillionColumnWhenTheEngineGaveNone() throws {
        var t = table()
        t.rows = t.rows.map { var r = $0; r.perMillion = nil; return r }
        let c = try controller(t)
        _ = c.view
        #expect(c.tableView.tableColumns.map(\.identifier.rawValue) == ["field0", "field1", "count", "percent"])
    }

    @Test func startsInTheOrderTheComposerAskedFor() throws {
        let c = try controller(table(), keys: [FrequencySortKey(.field(0), ascending: true), FrequencySortKey(.field(1), ascending: false)])
        _ = c.view
        #expect(c.displayedTable.rows.map(\.values) == [["give", "PRON"], ["give", "NOUN"], ["take", "PRON"]])
    }

    @Test func noKeysKeepsCountOrderHighestFirst() throws {
        let c = try controller(table())
        _ = c.view
        #expect(c.displayedTable.rows.map(\.count) == [6, 3, 2])
    }

    @Test func clickingAHeadingSortsByItAndKeepsTheOthersAsTieBreakers() throws {
        let c = try controller(table())
        _ = c.view
        c.tableView.sortDescriptors = [NSSortDescriptor(key: "field1", ascending: true), NSSortDescriptor(key: "count", ascending: false)]
        #expect(c.displayedTable.rows.map(\.values) == [["give", "NOUN"], ["take", "PRON"], ["give", "PRON"]])
        c.tableView.sortDescriptors = [NSSortDescriptor(key: "count", ascending: true)]
        #expect(c.displayedTable.rows.map(\.count) == [2, 3, 6])
    }

    @Test func descriptorsAndKeysRoundTrip() {
        let keys = [FrequencySortKey(.field(1), ascending: false), FrequencySortKey(.count, ascending: true),
                    FrequencySortKey(.percent, ascending: false), FrequencySortKey(.perMillion, ascending: true)]
        #expect(FrequencyViewController.keys(from: keys.map(FrequencyViewController.descriptor(for:))) == keys)
    }

    @Test func theFooterSaysHowManyHitsTheRowsCover() throws {
        let whole = try controller(table())
        _ = whole.view
        #expect(whole.footer.stringValue == "3 combinations, 11 hits.")
        var partial = table(cut: true, total: 1_000)
        partial.rows = Array(partial.rows.prefix(2))
        let cut = try controller(partial)
        _ = cut.view
        #expect(cut.footer.stringValue.contains("covering 9 of 1,000 hits"), "\(cut.footer.stringValue)")
        #expect(cut.footer.stringValue.contains("left out"))
    }

    @Test func aBigTableSortsInTheBackgroundAndArrives() async throws {
        let rows = (0..<6_000).map { FrequencyRow(values: ["w\(($0 * 31) % 6_000)", "X"], count: 6_000 - $0, percent: 0) }
        let big = FrequencyTable(fields: fields, rows: rows, totalMatches: 1)
        let c = try controller(big, keys: [FrequencySortKey(.field(0), ascending: true)])
        _ = c.view
        for _ in 0..<400 where c.displayedTable.rows.first?.values[0] != "w0" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(c.displayedTable.rows.first?.values[0] == "w0")
    }
}
