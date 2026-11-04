import Cocoa
import Testing
@testable import Korpora
@testable import KorporaEngine

/// The corpus list's handling of linked corpora: a moved folder shows as missing, and the commands that go with it.
@MainActor @Suite(.serialized) struct CorpusListLinkTests {
    private func list() -> CorporaSettingsViewController {
        let controller = CorporaSettingsViewController()
        _ = controller.view
        return controller
    }

    private func menuTitles(_ list: CorporaSettingsViewController, row: Int) -> [(String, Bool)] {
        list.tableView.selectRowIndexes([row], byExtendingSelection: false)
        let menu = list.tableView.menu!
        (menu.delegate as? NSMenuDelegate)?.menuNeedsUpdate?(menu)
        return menu.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0.isEnabled) }
    }

    private func movedLink(_ box: TestPando.Sandbox) throws -> URL {
        let target = try box.fakeIndex(named: "far", in: box.elsewhere, tokens: 5)
        try CorpusLibrary.link(indexDirectory: target, taken: [])
        let moved = box.elsewhere.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: target, to: moved)
        return moved
    }

    @Test func aCorpusWhoseFolderMovedStaysInTheListWithAWarning() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "mine", in: box.corpora)
        _ = try movedLink(box)
        let list = list()
        #expect(list.tableView.numberOfRows == 2, "listed, not silently gone")
        #expect(CorpusLibrary.names() == ["mine"], "but not offered for searching")

        let source = try #require(list.tableView.view(atColumn: 2, row: 0, makeIfNecessary: true) as? NSStackView)
        let icon = try #require(source.views.first as? NSImageView)
        #expect(icon.accessibilityLabel()?.hasPrefix("Missing") == true)
        let label = try #require(source.views.last as? NSTextField)
        #expect(label.stringValue == "Missing")
        #expect(label.toolTip?.contains("isn\u{2019}t at") == true && label.toolTip?.contains("Relink") == true)

        let builtSource = try #require(list.tableView.view(atColumn: 2, row: 1, makeIfNecessary: true) as? NSTextField)
        #expect(builtSource.stringValue == "Built", "no warning on a healthy corpus")

        let resident = try #require(list.tableView.view(atColumn: 4, row: 0, makeIfNecessary: true)?.subviews.first as? NSButton)
        #expect(!resident.isEnabled, "a missing corpus can't be kept in memory")
    }

    @Test func theContextualMenuOffersWhatFitsTheKindOfCorpus() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "built", in: box.corpora)
        let healthy = try box.fakeIndex(named: "healthy", in: box.elsewhere)
        try CorpusLibrary.link(indexDirectory: healthy, taken: [])
        _ = try movedLink(box)
        let list = list()
        let names = (0..<list.tableView.numberOfRows).map { row -> String in
            list.tableView.selectRowIndexes([row], byExtendingSelection: false)
            return list.selectedCorpusName ?? ""
        }
        let built = try #require(names.firstIndex(of: "built")), linked = try #require(names.firstIndex(of: "healthy")),
            missing = try #require(names.firstIndex(of: "far"))

        let builtMenu = menuTitles(list, row: built)
        #expect(builtMenu.map(\.0) == ["Show in Finder", "Rename", "Remove\u{2026}"], "nothing to relink in a built corpus")
        #expect(builtMenu.allSatisfy { $0.1 })

        let linkedMenu = menuTitles(list, row: linked)
        #expect(linkedMenu.map(\.0) == ["Show in Finder", "Rename", "Relink\u{2026}", "Bring into Korpora\u{2026}", "Remove\u{2026}"])
        #expect(linkedMenu.allSatisfy { $0.1 })

        let missingMenu = menuTitles(list, row: missing)
        #expect(missingMenu.map(\.0) == linkedMenu.map(\.0))
        #expect(missingMenu.filter { !$0.1 }.map(\.0) == ["Show in Finder", "Bring into Korpora\u{2026}"],
                "only Relink, Rename and Remove make sense without the folder")
    }

    @Test func doubleClickOpensAndReturnRenames() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "idx", in: box.corpora)
        let list = list()
        let table = list.tableView
        #expect(table.doubleAction != nil && table.target === list, "a double-click does something")
        #expect(table.action != nil)

        table.selectRowIndexes([0], byExtendingSelection: false)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)
        #expect(!cell.isEditable)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: event)
        #expect(cell.isEditable, "Return renames the selected corpus, as in Finder")
    }

    @Test func relinkingFromTheListPointsTheMissingCorpusAtItsNewFolder() throws {
        let box = try TestPando.Sandbox()
        let moved = try movedLink(box)
        let entry = try #require(CorpusLibrary.entries(includingMissing: true).first)
        let fixed = try CorpusLibrary.relink(entry, to: moved)
        #expect(fixed.tokens == 5)
        let list = list()
        let source = try #require(list.tableView.view(atColumn: 2, row: 0, makeIfNecessary: true) as? NSTextField)
        #expect(source.stringValue == "Linked")
    }
}
