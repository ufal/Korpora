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

    @Test func sourceLabels() {
        #expect(CorporaSettingsViewController.sourceTitle(.built) == "Built by Korpora")
        #expect(CorporaSettingsViewController.sourceTitle(.linked(target: URL(fileURLWithPath: "/x"))) == "Linked folder")
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
}
