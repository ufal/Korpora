import Foundation
import KorporaEngine
import Testing
@testable import Korpora

/// The app side of the corpus list (docs/pando-gui-plan.md): "Keep in Memory" flags stored per corpus
/// name, how the sources are labelled, and the Corpora pane keeping its selection while it refreshes.
/// Serialized: the library folders are process environment variables.
@Suite(.serialized) struct CorpusListSettingsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CorpusListSettingsTests-\(UUID().uuidString)")!
    }

    @Test func keepResidentFlagsAreStoredPerName() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.keepResidentCorpora.isEmpty)
        settings.setKeepResident(true, for: "syn2025")
        settings.setKeepResident(true, for: "ud")
        settings.setKeepResident(false, for: "ud")
        #expect(settings.isKeepResident("syn2025"))
        #expect(!settings.isKeepResident("ud"))
        #expect(settings.keepResidentCorpora == ["syn2025"])
    }

    @Test func theDefaultViewIsKwicUntilChosen() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.defaultViewMode == .kwic)
        settings.defaultViewMode = .sentence
        #expect(settings.defaultViewMode == .sentence)
    }

    @Test func sourceLabels() {
        #expect(CorporaSettingsViewController.sourceTitle(.built) == "Built")
        #expect(CorporaSettingsViewController.sourceTitle(.linked(target: URL(fileURLWithPath: "/x"))) == "Linked")
        #expect(CorporaSettingsViewController.sourceDetail(.linked(target: URL(fileURLWithPath: "/x"))).contains("/x"))
    }

    @Test func theLibraryFeedsTheSettingsList() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "beta", tokens: 5)
        try box.fakeIndex(named: "alpha", tokens: 7)
        let entries = AppSettings(defaults: freshDefaults()).corpusLibraryEntries()
        #expect(entries.map(\.name) == ["alpha", "beta"])
        #expect(entries.map(\.tokens) == [7, 5])
    }

    @Test func theLoadLimitHasAFloorAndADefault() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.maxConcordanceLines == ConcordanceLimit.defaultLimit)
        settings.maxConcordanceLines = 250_000
        #expect(settings.maxConcordanceLines == 250_000)
    }

    /// The Corpora pane refreshes itself every 2 seconds (memory gauge and
    /// the Keep in Memory checkboxes). It used to `reloadData()` the whole
    /// table each time, which cleared the selection before "\u{2212}" could be
    /// clicked (macOS 15 smoke test of 0.2).
    @MainActor @Test func selectionSurvivesTheRefreshTimerAndReloads() throws {
        let box = try TestPando.Sandbox()
        for name in ["one", "two", "three"] { try box.fakeIndex(named: name) }

        let controller = CorporaSettingsViewController()
        _ = controller.view
        let table = controller.tableView
        var target: Int?
        for row in 0..<table.numberOfRows {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if controller.selectedCorpusName == "two" { target = row }
        }
        let row = try #require(target)
        table.selectRowIndexes([row], byExtendingSelection: false)

        controller.refreshMemoryDependentColumn()
        #expect(controller.selectedCorpusName == "two")
        controller.reloadCorpora()
        #expect(controller.selectedCorpusName == "two")
    }

    @Test func reorderingMovesTheDraggedCorporaToTheGapKeepingTheirOrder() {
        let names = ["a", "b", "c", "d", "e"]
        typealias C = CorporaSettingsViewController
        #expect(C.reordered(names, moving: ["d"], toGap: 0) == ["d", "a", "b", "c", "e"])
        #expect(C.reordered(names, moving: ["a"], toGap: 5) == ["b", "c", "d", "e", "a"])
        #expect(C.reordered(names, moving: ["b"], toGap: 4) == ["a", "c", "d", "b", "e"])
        #expect(C.reordered(names, moving: ["d", "b"], toGap: 1) == ["a", "b", "d", "c", "e"], "the dragged ones keep their order")
        #expect(C.reordered(names, moving: ["c"], toGap: 2) == names, "dropped where it is")
        #expect(C.reordered(names, moving: ["c"], toGap: 3) == names)
    }

    @Test func theOrderIsStoredAndAFollowsARename() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.corpusOrder.isEmpty)
        settings.corpusOrder = ["ud", "syn", "cats"]
        #expect(AppSettings(defaults: settings.defaults).corpusOrder == ["ud", "syn", "cats"])
        settings.renameInCorpusOrder(from: "syn", to: "syn2025")
        #expect(settings.corpusOrder == ["ud", "syn2025", "cats"])
        settings.renameInCorpusOrder(from: "not there", to: "x")
        #expect(settings.corpusOrder == ["ud", "syn2025", "cats"])
    }

    /// A click on a heading sorts the list and that is the new order, which the New Concordance pop-up uses too.
    @MainActor @Test func clickingAHeadingSortsTheListAndKeepsItAsTheOrder() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "alpha", tokens: 7)
        try box.fakeIndex(named: "beta", tokens: 5)
        try box.fakeIndex(named: "gamma", tokens: 9)
        // The test host shares the app's own defaults: put them back as they were.
        let shared = AppSettings.shared
        let saved = shared.defaults.object(forKey: "corpusOrder")
        defer {
            if let saved { shared.defaults.set(saved, forKey: "corpusOrder") } else { shared.defaults.removeObject(forKey: "corpusOrder") }
            CorpusLibrary.customOrder = shared.corpusOrder
        }
        shared.defaults.removeObject(forKey: "corpusOrder")
        CorpusLibrary.customOrder = []

        let controller = CorporaSettingsViewController()
        _ = controller.view
        controller.tableView.sortDescriptors = [NSSortDescriptor(key: "tokens", ascending: false)]
        #expect(CorpusLibrary.names() == ["gamma", "alpha", "beta"])
        controller.tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        #expect(CorpusLibrary.names() == ["gamma", "beta", "alpha"])
        #expect(shared.corpusOrder == ["gamma", "beta", "alpha"])
    }
}
