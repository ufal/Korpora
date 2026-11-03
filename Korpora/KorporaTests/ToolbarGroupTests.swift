import Cocoa
import Testing
@testable import Korpora

/// The concordance toolbar's logical groups (the HIG: group items by function and frequency of use, at most three
/// groups, fixed space between them), so that with text labels shown related items stay one control.
@MainActor @Suite(.serialized) struct ToolbarGroupTests {
    private func shownController() -> ConcordanceWindowController {
        let document = ConcordanceDocument()
        document.historyDefaults = UserDefaults(suiteName: "ToolbarGroupTests-\(UUID().uuidString)")!
        let controller = ConcordanceWindowController(document: document)
        _ = controller.window
        return controller
    }

    @Test func theToolbarHasThreeGroupsBetweenFixedSpaces() {
        let controller = shownController()
        let ids = controller.toolbarDefaultItemIdentifiers(NSToolbar())
        let ItemID = ConcordanceWindowController.ItemID.self
        #expect(ids == [ItemID.history, .space, ItemID.resultGroup, .space, ItemID.displayGroup, .space,
                        ItemID.analysisGroup, .flexibleSpace, ItemID.operations])
        #expect(ConcordanceWindowController.groups.count <= 3, "the HIG: no more than three groups")
    }

    @Test func everyActionIsInExactlyOneGroup() {
        let ItemID = ConcordanceWindowController.ItemID.self
        let leaves = ConcordanceWindowController.groups.flatMap(\.items)
        let expected: Set<NSToolbarItem.Identifier> = [ItemID.sort, ItemID.shuffle, ItemID.sample, ItemID.context,
                                                       ItemID.attributes, ItemID.collocations, ItemID.frequencies, ItemID.dispersion]
        #expect(Set(leaves) == expected)
        #expect(leaves.count == expected.count, "none twice")
    }

    @Test func eachGroupIsOneExpandedControlOfItsItemsWithTheirOwnLabels() throws {
        let controller = shownController()
        let toolbar = try #require(controller.window?.toolbar)
        for group in ConcordanceWindowController.groups {
            let built = controller.toolbar(toolbar, itemForItemIdentifier: group.id, willBeInsertedIntoToolbar: true)
            let item = try #require(built as? NSToolbarItemGroup)
            #expect(item.subitems.map(\.itemIdentifier) == group.items, Comment(rawValue: group.title))
            #expect(item.selectionMode == .momentary, "actions, not a choice")
            #expect(item.controlRepresentation == .expanded, "not collapsed into a pop-up")
            #expect(item.label.isEmpty, "each item keeps its own label")
            for sub in item.subitems {
                #expect(!sub.label.isEmpty && sub.view is NSButton, "\(sub.itemIdentifier.rawValue)")
                #expect((sub.view as? NSButton)?.toolTip?.isEmpty == false, "and a tooltip")
            }
        }
    }

    @Test func historyAndOperationsStandAloneAtTheEnds() throws {
        let controller = shownController()
        let toolbar = try #require(controller.window?.toolbar)
        let ItemID = ConcordanceWindowController.ItemID.self
        for id in [ItemID.history, ItemID.operations] {
            let item = try #require(controller.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true))
            #expect(!(item is NSToolbarItemGroup) && item.view is NSButton)
        }
    }

    /// The buttons inside the groups are the ones the document's state switches on and off.
    @Test func lineGroupsStillDisableSortShuffleAndSampleInsideTheirGroup() throws {
        let controller = shownController()
        let toolbar = try #require(controller.window?.toolbar)
        let ItemID = ConcordanceWindowController.ItemID.self
        let group = try #require(controller.toolbar(toolbar, itemForItemIdentifier: ItemID.resultGroup, willBeInsertedIntoToolbar: true)
                                 as? NSToolbarItemGroup)
        let buttons = group.subitems.compactMap { $0.view as? NSButton }
        #expect(buttons.count == 3 && buttons.allSatisfy { $0.isEnabled })
        controller.updateToolbarState(hasLineGroups: true)
        #expect(buttons.allSatisfy { !$0.isEnabled })
        controller.updateToolbarState(hasLineGroups: false)
        #expect(buttons.allSatisfy { $0.isEnabled })
        // Context (in the Display group) is a display setting and is never switched off.
        let display = try #require(controller.toolbar(toolbar, itemForItemIdentifier: ItemID.displayGroup, willBeInsertedIntoToolbar: true)
                                   as? NSToolbarItemGroup)
        controller.updateToolbarState(hasLineGroups: true)
        #expect(display.subitems.compactMap { $0.view as? NSButton }.allSatisfy { $0.isEnabled })
    }

    @Test func theRealToolbarHoldsTheGroupsAndSpaces() throws {
        let controller = shownController()
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let ids = try #require(window.toolbar).items.map(\.itemIdentifier)
        let ItemID = ConcordanceWindowController.ItemID.self
        #expect(ids.contains(ItemID.resultGroup) && ids.contains(ItemID.displayGroup) && ids.contains(ItemID.analysisGroup))
        #expect(!ids.contains(ItemID.sort), "a grouped action is not also a loose item")
        #expect(ids.filter { $0 == .space }.count == 3)
    }
}
