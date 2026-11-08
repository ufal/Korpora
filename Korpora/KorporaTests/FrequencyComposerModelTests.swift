import Foundation
import Testing
import KorporaEngine
@testable import Korpora

@Suite struct FrequencyComposerModelTests {
    private func node(_ name: String, _ attribute: String) -> ComposerRow.Kind { .node(name, attribute: attribute) }

    @Test func startsWithOnlyTheCount() {
        let model = FrequencyComposerModel()
        #expect(model.rows.map(\.kind) == [.count])
        #expect(model.isEmpty)
        #expect(model.fields.isEmpty)
        #expect(model.sortKeys.isEmpty)
    }

    @Test func newFieldsGoBeforeTheCountWhileItIsLast() {
        var model = FrequencyComposerModel()
        let added1 = model.add(node("a", "lemma"))
        #expect(added1)
        let added2 = model.add(node("b", "upos"))
        #expect(added2)
        #expect(model.rows.map(\.kind) == [node("a", "lemma"), node("b", "upos"), .count])
        #expect(model.fields == [FrequencyField(node: "a", attribute: "lemma"), FrequencyField(node: "b", attribute: "upos")])
    }

    @Test func aMovedCountStaysWhereTheUserPutIt() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma"))
        model.move(from: 1, toGap: 0)                      // the count to the top
        model.add(node("b", "upos"))
        #expect(model.rows.map(\.kind) == [.count, node("a", "lemma"), node("b", "upos")])
    }

    @Test func theSameFieldIsNotAddedTwice() {
        var model = FrequencyComposerModel()
        let added3 = model.add(node("a", "lemma"))
        #expect(added3)
        let added4 = model.add(node("a", "lemma"))
        #expect(!added4)
        let added5 = model.add(node("b", "lemma"))
        #expect(added5)
        let added6 = model.add(.property(attribute: "doc.genre"))
        #expect(added6)
        let added7 = model.add(.property(attribute: "doc.genre"))
        #expect(!added7)
        let added8 = model.add(.count)
        #expect(!added8)
        #expect(model.fieldRows.count == 3)
    }

    @Test func propertiesAreFieldsWithoutANode() {
        var model = FrequencyComposerModel()
        model.add(.property(attribute: "doc.genre"), ignoreCase: true)
        #expect(model.fields == [FrequencyField(node: nil, attribute: "doc.genre", ignoreCase: true)])
    }

    @Test func removingDropsAFieldButNeverTheCount() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma"))
        let count = model.rows.last!
        model.remove(count.id)
        #expect(model.rows.count == 2)
        model.remove(model.rows[0].id)
        #expect(model.rows.map(\.kind) == [.count])
    }

    @Test func moveUsesTheGapAboveARow() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma")); model.add(node("b", "upos")); model.add(node("c", "form"))
        // rows: a b c count. Drag a to the gap above c (index 2): b a c count.
        model.move(from: 0, toGap: 2)
        #expect(model.rows.map(\.kind) == [node("b", "upos"), node("a", "lemma"), node("c", "form"), .count])
        // Drag c to the very top.
        model.move(from: 2, toGap: 0)
        #expect(model.rows.map(\.kind) == [node("c", "form"), node("b", "upos"), node("a", "lemma"), .count])
        // Drag b to the bottom (the gap after the last row).
        model.move(from: 1, toGap: model.rows.count)
        #expect(model.rows.map(\.kind) == [node("c", "form"), node("a", "lemma"), .count, node("b", "upos")])
    }

    @Test func changingTheAttributeKeepsTheNodeAndRefusesADuplicate() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma")); model.add(node("a", "upos"))
        let first = model.rows[0].id
        model.setAttribute("upos", for: first)
        #expect(model.rows[0].kind == node("a", "lemma"), "a would then ask for a.upos twice")
        model.setAttribute("form", for: first)
        #expect(model.rows[0].kind == node("a", "form"))
        model.add(.property(attribute: "doc.genre"))
        model.setAttribute("doc.author", for: model.rows[2].id)
        #expect(model.rows[2].kind == .property(attribute: "doc.author"))
    }

    @Test func movingALineToAnotherNodeKeepsTheAttributeAndRefusesADuplicate() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma")); model.add(node("b", "lemma")); model.add(.property(attribute: "doc.genre"))
        let first = model.rows[0].id
        let duplicate = model.setNode("b", for: first)
        #expect(!duplicate, "b.lemma is already a line")
        #expect(model.rows[0].kind == node("a", "lemma"))
        model.add(node("a", "upos"))
        // The rows are now a.lemma, b.lemma, doc.genre, a.upos, count.
        let moved = model.setNode("c", for: model.rows[3].id)
        #expect(moved)
        #expect(model.rows[3].kind == node("c", "upos"), "the attribute stays")
        let again = model.setNode("c", for: model.rows[3].id)
        #expect(again, "the same node again is no change, and no refusal")
        // Not a node's line: the property and the count have no node to change.
        let property = model.setNode("a", for: model.rows[2].id)
        let count = model.setNode("a", for: model.rows.last!.id)
        #expect(!property && !count)
        #expect(model.rows.last?.kind == .count)
    }

    @Test func sortCyclesNoneAscendingDescending() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma"))
        let id = model.rows[0].id
        #expect(model.rows[0].sort == .none)
        model.cycleSort(for: id); #expect(model.rows[0].sort == .ascending)
        model.cycleSort(for: id); #expect(model.rows[0].sort == .descending)
        model.cycleSort(for: id); #expect(model.rows[0].sort == .none)
    }

    @Test func sortKeysFollowTheOrderOfTheRowsAndIndexTheFields() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma")); model.add(node("b", "upos"))
        // rows: a, b, count. Count first, then b descending, then a ascending.
        model.move(from: 2, toGap: 0)
        for index in 0..<3 { model.cycleSort(for: model.rows[index].id) }          // all ascending
        model.cycleSort(for: model.rows[2].id)                                     // b (now row 2) descending
        #expect(model.sortKeys == [
            FrequencySortKey(.count, ascending: true),
            FrequencySortKey(.field(0), ascending: true),
            FrequencySortKey(.field(1), ascending: false),
        ])
    }

    @Test func noSortSetMeansNoKeys() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma"))
        #expect(model.sortKeys.isEmpty)
    }

    @Test func ignoreCaseIsPerFieldAndNotForTheCount() {
        var model = FrequencyComposerModel()
        model.add(node("a", "form")); model.add(node("b", "lemma"))
        model.setIgnoreCase(true, for: model.rows[0].id)
        model.setIgnoreCase(true, for: model.rows[2].id)                           // the count: ignored
        #expect(model.fields.map(\.ignoreCase) == [true, false])
        #expect(model.rows[2].ignoreCase == false)
    }

    @Test func rowsAboutNodesTheQueryLostAreDropped() {
        var model = FrequencyComposerModel()
        model.add(node("a", "lemma")); model.add(node("b", "upos")); model.add(.property(attribute: "doc.genre"))
        model.keepOnly(nodes: ["a"])
        #expect(model.rows.map(\.kind) == [node("a", "lemma"), .property(attribute: "doc.genre"), .count])
    }
}
