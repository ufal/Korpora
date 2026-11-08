import Foundation
import XCTest
@testable import KorporaEngine

final class FrequencySortTests: XCTestCase {
    private func table(_ rows: [([String], Int)]) -> FrequencyTable {
        FrequencyTable(fields: [FrequencyField(node: "a", attribute: "lemma"), FrequencyField(node: "b", attribute: "upos")],
                       rows: rows.map { FrequencyRow(values: $0.0, count: $0.1, percent: Double($0.1)) },
                       totalMatches: rows.reduce(0) { $0 + $1.1 })
    }

    func testNoKeysLeavesTheTableAsPandoGaveIt() {
        let t = table([(["b", "X"], 5), (["a", "Y"], 3)])
        XCTAssertEqual(t.sorted(by: []), t)
    }

    func testAFieldAscendingThenCountForTies() {
        let t = table([(["cat", "NOUN"], 9), (["dog", "NOUN"], 7), (["cat", "VERB"], 2), (["ant", "NOUN"], 1)])
        let sorted = t.sorted(by: [FrequencySortKey(.field(0), ascending: true)])
        XCTAssertEqual(sorted.rows.map(\.values), [["ant", "NOUN"], ["cat", "NOUN"], ["cat", "VERB"], ["dog", "NOUN"]])
    }

    func testPriorityIsTheOrderOfTheKeys() {
        let t = table([(["a", "Y"], 1), (["b", "X"], 2), (["a", "X"], 3), (["b", "Y"], 4)])
        let byFirst = t.sorted(by: [FrequencySortKey(.field(0), ascending: true), FrequencySortKey(.field(1), ascending: false)])
        XCTAssertEqual(byFirst.rows.map(\.values), [["a", "Y"], ["a", "X"], ["b", "Y"], ["b", "X"]])
        let bySecond = t.sorted(by: [FrequencySortKey(.field(1), ascending: false), FrequencySortKey(.field(0), ascending: true)])
        XCTAssertEqual(bySecond.rows.map(\.values), [["a", "Y"], ["b", "Y"], ["a", "X"], ["b", "X"]])
    }

    func testCountAscendingAndDescending() {
        let t = table([(["a", "X"], 5), (["b", "X"], 1), (["c", "X"], 3)])
        XCTAssertEqual(t.sorted(by: [FrequencySortKey(.count, ascending: true)]).rows.map(\.count), [1, 3, 5])
        XCTAssertEqual(t.sorted(by: [FrequencySortKey(.count, ascending: false)]).rows.map(\.count), [5, 3, 1])
    }

    func testTextIsCollatedNotCompared() {
        // Code-point order would put Z before a and ž after z.
        let t = table([(["zebra", "X"], 1), (["Zebra2", "X"], 1), (["apple", "X"], 1), (["Árpád", "X"], 1), (["10", "X"], 1), (["9", "X"], 1)])
        let sorted = t.sorted(by: [FrequencySortKey(.field(0), ascending: true)]).rows.map { $0.values[0] }
        XCTAssertEqual(sorted, ["9", "10", "apple", "Árpád", "zebra", "Zebra2"])
    }

    func testEqualRowsKeepPandosOrder() {
        let t = table([(["same", "X"], 2), (["same", "X"], 2), (["same", "X"], 2)].enumerated().map { (["same", "X\($0.offset)"], 2) })
        let sorted = t.sorted(by: [FrequencySortKey(.field(0), ascending: true)])
        XCTAssertEqual(sorted.rows.map(\.values.last!), ["X0", "X1", "X2"])
    }

    func testSortingAHundredThousandRowsIsQuick() {
        let rows = (0..<100_000).map { (["word\(($0 * 7919) % 100_000)", "NOUN"], 100_000 - $0) }
        let t = table(rows)
        let start = Date()
        let sorted = t.sorted(by: [FrequencySortKey(.field(0), ascending: true)])
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(sorted.rows.first?.values[0], "word0")
        XCTAssertLessThan(seconds, 5, "sorting 100,000 rows took \(seconds) s")
        print("sorted 100,000 rows by text in \(seconds) s")
    }
}
