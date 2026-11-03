import Cocoa
import KorporaEngine
import Testing
@testable import Korpora

/// The Settings window as other parts of the app send the user to it, and the per-script font list.
@MainActor @Suite(.serialized) struct SettingsFlowTests {
    private func freshSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "SettingsFlowTests-\(UUID().uuidString)")!)
    }

    // MARK: No corpora yet -> Settings

    /// The button on the New Concordance sheet with an empty library opens the Settings window, in front,
    /// on the Corpora tab, and leaves the sheet where it is.
    @Test func theNoCorporaButtonOpensSettingsOnTheCorporaTab() throws {
        let box = try TestPando.Sandbox()
        _ = box
        let window = SettingsWindowController.shared
        window.showPane(.appearance)
        window.window?.orderOut(nil)

        let sheet = NewConcordanceSheetController()
        _ = sheet.view
        let button = try #require(allButtons(in: sheet.view).first { $0.title == "Open Corpora Settings\u{2026}" })
        #expect(!button.isHidden, "shown while there are no corpora")
        button.performClick(nil)

        #expect(window.window?.isVisible == true)
        #expect(window.window?.contentViewController is CorporaSettingsViewController)
        #expect(window.window?.title == "Corpora")
        window.window?.orderOut(nil)
    }

    @Test func theButtonIsHiddenAndSearchEnabledOnceThereIsACorpus() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "Ready")
        let sheet = NewConcordanceSheetController()
        _ = sheet.view
        let button = try #require(allButtons(in: sheet.view).first { $0.title == "Open Corpora Settings\u{2026}" })
        #expect(button.isHidden)
        let search = try #require(allButtons(in: sheet.view).first { $0.title == "Search" })
        #expect(search.isEnabled)
    }

    /// A corpus added in Settings while the sheet is open appears in its list.
    @Test func theSheetPicksUpACorpusAddedWhileItIsOpen() throws {
        let box = try TestPando.Sandbox()
        let sheet = NewConcordanceSheetController()
        _ = sheet.view
        let search = try #require(allButtons(in: sheet.view).first { $0.title == "Search" })
        let popUp = try #require(allViews(NSPopUpButton.self, in: sheet.view).first)
        #expect(!search.isEnabled && !popUp.isEnabled && popUp.titleOfSelectedItem == "No corpora yet")

        try box.fakeIndex(named: "Arrived", tokens: 42)
        NotificationCenter.default.post(name: AppSettings.corporaDidChangeNotification, object: nil)

        #expect(popUp.isEnabled && popUp.titleOfSelectedItem == "Arrived")
        #expect(search.isEnabled)
        let hidden = try #require(allButtons(in: sheet.view).first { $0.title == "Open Corpora Settings\u{2026}" }).isHidden
        #expect(hidden)
    }

    @Test func theCorporaPaneAnnouncesChanges() throws {
        let box = try TestPando.Sandbox()
        _ = box
        let controller = CorporaSettingsViewController()
        _ = controller.view
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppSettings.corporaDidChangeNotification, object: nil, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        controller.reloadCorpora()
        #expect(count == 1)
    }

    // MARK: Per-script fonts

    private func appearance(_ settings: AppSettings) -> AppearanceSettingsViewController {
        let controller = AppearanceSettingsViewController()
        controller.settings = settings
        _ = controller.view
        return controller
    }

    @Test func aScriptFontCanBeChangedLater() throws {
        let settings = freshSettings()
        settings.scriptFontOverrides = ["greek": "Times-Roman", "cyrillic": "Helvetica"]
        let controller = appearance(settings)
        #expect(controller.scriptOverrideRows.map(\.script) == [.cyrillic, .greek])

        let greek = try #require(controller.scriptOverrideRows.firstIndex { $0.script == .greek })
        controller.scriptTableView.selectRowIndexes([greek], byExtendingSelection: false)
        #expect(controller.changeScriptFontButton.isEnabled && controller.removeScriptFontButton.isEnabled)

        let newFont = try #require(NSFont(name: "Courier", size: 12))
        controller.applyFont(newFont, to: .greek)
        #expect(settings.scriptFontOverrides["greek"] == "Courier")
        #expect(settings.scriptFontOverrides["cyrillic"] == "Helvetica", "others unchanged")
        #expect(controller.scriptOverrideRows.first { $0.script == .greek }?.fontName == "Courier")
        // The selection stays on the row that was changed.
        #expect(controller.scriptTableView.selectedRow == controller.scriptOverrideRows.firstIndex { $0.script == .greek })

        // Changing it again (the Font Panel keeps sending changes) is applied too.
        controller.applyFont(try #require(NSFont(name: "Menlo-Regular", size: 12)), to: .greek)
        #expect(settings.scriptFontOverrides["greek"] == "Menlo-Regular")
    }

    @Test func theChangeButtonAndDoubleClickAreWired() throws {
        let settings = freshSettings()
        settings.scriptFontOverrides = ["greek": "Times-Roman"]
        let controller = appearance(settings)
        #expect(!controller.changeScriptFontButton.isEnabled, "nothing selected")
        #expect(controller.changeScriptFontButton.title == "Change Font\u{2026}")
        #expect(controller.changeScriptFontButton.action == controller.scriptTableView.doubleAction,
                "double-clicking a row does what the button does")
        controller.scriptTableView.selectRowIndexes([0], byExtendingSelection: false)
        #expect(controller.changeScriptFontButton.isEnabled)
        // It points the Font Panel at that script.
        controller.changeScriptFontButton.performClick(nil)
        #expect(controller.pendingScript == .greek)
        #expect(NSFontManager.shared.target === controller)
        NSFontPanel.shared.orderOut(nil)
    }

    @Test func theFontPanelFollowsTheSelectedRow() throws {
        let settings = freshSettings()
        settings.scriptFontOverrides = ["greek": "Times-Roman", "hebrew": "Helvetica"]
        let controller = appearance(settings)
        controller.scriptTableView.selectRowIndexes([0], byExtendingSelection: false)
        controller.changeScriptFontButton.performClick(nil)
        let first = controller.pendingScript
        controller.scriptTableView.selectRowIndexes([1], byExtendingSelection: false)
        #expect(controller.pendingScript != first && controller.pendingScript != nil)
        NSFontPanel.shared.orderOut(nil)
    }

    @Test func removingTheSelectedScriptFontForgetsIt() throws {
        let settings = freshSettings()
        settings.scriptFontOverrides = ["greek": "Times-Roman"]
        let controller = appearance(settings)
        controller.scriptTableView.selectRowIndexes([0], byExtendingSelection: false)
        controller.removeScriptFontButton.performClick(nil)
        #expect(settings.scriptFontOverrides.isEmpty)
        #expect(controller.scriptOverrideRows.isEmpty)
        #expect(!controller.changeScriptFontButton.isEnabled)
    }

    // MARK: Helpers

    private func allViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { allViews(type, in: $0) }
    }

    private func allButtons(in view: NSView) -> [NSButton] { allViews(NSButton.self, in: view) }
}

/// Naming and renaming corpora from the Corpora list.
@MainActor @Suite(.serialized) struct CorpusRenamingTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "CorpusRenamingTests-\(UUID().uuidString)")! }

    private func controller() -> CorporaSettingsViewController {
        let controller = CorporaSettingsViewController()
        _ = controller.view
        return controller
    }

    @Test func renamingMovesTheCorpusAndEverythingKeptUnderItsName() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "idx", tokens: 12)
        AppSettings.shared.setKeepResident(true, for: "idx")
        defer { AppSettings.shared.setKeepResident(false, for: "Syn2025"); AppSettings.shared.setKeepResident(false, for: "idx") }
        try SubcorpusLibrary.save(Subcorpus(name: "Fiction", restriction: SubcorpusRestriction()), in: "idx")
        QueryHistoryStore.record(corpusName: "idx", subcorpusName: nil, query: "[]")
        defer { QueryHistoryStore.clear() }

        let list = controller()
        let renamed = try list.renameCorpus(named: "idx", to: "Syn2025")

        #expect(renamed.name == "Syn2025")
        #expect(CorpusLibrary.names() == ["Syn2025"])
        #expect(list.selectedCorpusName == nil || list.selectedCorpusName == "Syn2025")
        #expect(AppSettings.shared.isKeepResident("Syn2025") && !AppSettings.shared.isKeepResident("idx"))
        #expect(SubcorpusLibrary.subcorpora(of: "Syn2025").map(\.name) == ["Fiction"])
        #expect(SubcorpusLibrary.subcorpora(of: "idx").isEmpty)
        #expect(QueryHistoryStore.recentEntries().first?.corpusName == "Syn2025")
        #expect(list.tableView.numberOfRows == 1)
    }

    @Test func aTakenOrUnusableNameChangesNothing() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "one")
        try box.fakeIndex(named: "two")
        let list = controller()
        #expect(throws: CorpusLibrary.LibraryError.self) { try list.renameCorpus(named: "one", to: "two") }
        #expect(throws: CorpusLibrary.LibraryError.self) { try list.renameCorpus(named: "one", to: "  ") }
        #expect(throws: CorpusLibrary.LibraryError.self) { try list.renameCorpus(named: "one", to: "a/b") }
        #expect(CorpusLibrary.names() == ["one", "two"])
    }

    /// Typing a new name into the list's name cell, as a user does.
    @Test func editingTheNameInTheListRenames() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "idx")
        let list = controller()
        let cell = try #require(list.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)
        #expect(cell.isEditable, "the name can be edited in place")
        #expect(cell.delegate === list, "and a finished edit reaches the list, which renames")
        #expect(cell.stringValue == "idx")

        cell.stringValue = "Czech National Corpus"
        list.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: cell))
        #expect(CorpusLibrary.names() == ["Czech National Corpus"])
    }

    @Test func aRejectedEditPutsTheOldNameBack() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "one")
        try box.fakeIndex(named: "two")
        let list = controller()
        let cell = try #require(list.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)
        let old = cell.stringValue
        cell.stringValue = old == "one" ? "two" : "one"   // the other corpus's name
        list.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: cell))
        #expect(cell.stringValue == old)
        #expect(CorpusLibrary.names() == ["one", "two"])
    }

    @Test func linkingAFolderDoesNotRenameTheFolder() throws {
        let box = try TestPando.Sandbox()
        let folder = box.root.appendingPathComponent("syn2025/idx")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "size=1\n".write(to: folder.appendingPathComponent("corpus.info"), atomically: true, encoding: .utf8)
        try CorpusLibrary.link(indexDirectory: folder, name: "SYN2025", taken: [])
        let list = controller()
        try list.renameCorpus(named: "SYN2025", to: "Syn")
        #expect(CorpusLibrary.names() == ["Syn"])
        #expect(CorpusLibrary.isCorpus(folder), "the folder keeps its name and content")
    }

    @Test func historyAndFlagsFollowARenameInTheirOwnStores() {
        let d = defaults()
        QueryHistoryStore.record(corpusName: "a", subcorpusName: nil, query: "[1]", defaults: d)
        QueryHistoryStore.record(corpusName: "b", subcorpusName: nil, query: "[2]", defaults: d)
        QueryHistoryStore.renameCorpus(from: "a", to: "z", defaults: d)
        #expect(Set(QueryHistoryStore.recentEntries(defaults: d).map(\.corpusName)) == ["z", "b"])
        QueryHistoryStore.renameCorpus(from: "missing", to: "q", defaults: d)
        #expect(QueryHistoryStore.recentEntries(defaults: d).count == 2)

        let settings = AppSettings(defaults: defaults())
        settings.setKeepResident(true, for: "a")
        settings.renameKeepResident(from: "a", to: "z")
        #expect(settings.keepResidentCorpora == ["z"])
        settings.renameKeepResident(from: "nothing", to: "other")
        #expect(settings.keepResidentCorpora == ["z"], "a corpus that wasn't kept in memory stays out")
    }
}
