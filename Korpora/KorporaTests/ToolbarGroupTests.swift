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
            #expect(item.subitems.map(\.label) == group.items.map { ConcordanceWindowController.label(for: $0) }, Comment(rawValue: group.title))
            #expect(item.selectionMode == .momentary, "actions, not a choice")
            #expect(item.controlRepresentation == .expanded, "not collapsed into a pop-up")
            #expect(item.label.isEmpty, "each item keeps its own label")
            for sub in item.subitems {
                #expect(!sub.label.isEmpty && sub.image != nil, "\(sub.itemIdentifier.rawValue)")
                #expect(sub.toolTip?.isEmpty == false, "and a tooltip")
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
        let buttons = group.subitems
        #expect(buttons.count == 3 && buttons.allSatisfy { $0.isEnabled })
        controller.updateToolbarState(hasLineGroups: true)
        #expect(buttons.allSatisfy { !$0.isEnabled })
        controller.updateToolbarState(hasLineGroups: false)
        #expect(buttons.allSatisfy { $0.isEnabled })
        // Context (in the Display group) is a display setting and is never switched off.
        let display = try #require(controller.toolbar(toolbar, itemForItemIdentifier: ItemID.displayGroup, willBeInsertedIntoToolbar: true)
                                   as? NSToolbarItemGroup)
        controller.updateToolbarState(hasLineGroups: true)
        #expect(display.subitems.allSatisfy { $0.isEnabled })
    }

    /// A click on Sort (a popover) and on Shuffle runs the item's action; the popover needs a real
    /// view to hang from (it once got a toolbar item, which has no bounds).
    @Test func clickingSegmentsRunsTheirActions() throws {
        let controller = shownController()
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let toolbar = try #require(window.toolbar)
        let result = try #require(toolbar.items.first { $0.itemIdentifier == ConcordanceWindowController.ItemID.resultGroup } as? NSToolbarItemGroup)
        for index in [0, 1, 2] {  // Sort, Shuffle, Sample
            result.selectedIndex = index
            _ = result.target?.perform(result.action, with: result)
        }
        let display = try #require(toolbar.items.first { $0.itemIdentifier == ConcordanceWindowController.ItemID.displayGroup } as? NSToolbarItemGroup)
        for index in [0, 1] {  // Context, Attributes
            display.selectedIndex = index
            _ = display.target?.perform(display.action, with: display)
        }
        for popoverWindow in NSApp.windows where popoverWindow !== window && popoverWindow.className.contains("Popover") { popoverWindow.close() }
    }

    /// The view a popover hangs from is left over the segment afterwards; it must not catch the
    /// next click on that segment.
    @Test func theLeftoverPopoverAnchorDoesNotCatchClicks() throws {
        let controller = shownController()
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let toolbar = try #require(window.toolbar)
        let display = try #require(toolbar.items.first { $0.itemIdentifier == ConcordanceWindowController.ItemID.displayGroup } as? NSToolbarItemGroup)
        display.selectedIndex = 1
        _ = display.target?.perform(display.action, with: display)
        func segmented(_ view: NSView) -> [NSSegmentedControl] { ((view as? NSSegmentedControl).map { [$0] } ?? []) + view.subviews.flatMap(segmented) }
        let root = try #require(window.contentView?.superview)
        let control = try #require(segmented(root).first { $0.segmentCount == 2 })
        let anchors = control.subviews.filter { $0 is NSButton }
        #expect(!anchors.isEmpty)
        for anchor in anchors {
            #expect(control.hitTest(control.convert(NSPoint(x: anchor.frame.midX, y: anchor.frame.midY), to: control.superview)) !== anchor)
        }
        for popoverWindow in NSApp.windows where popoverWindow !== window && popoverWindow.className.contains("Popover") { popoverWindow.close() }
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

    // MARK: Menu commands and customization

    /// HIG: every toolbar action is also a command in the menu bar.
    @Test func everyToolbarActionIsAlsoAQueryMenuCommand() throws {
        let menu = try #require(NSApp.mainMenu)
        let queryMenu = try #require(menu.items.first { $0.submenu?.title == "Query" }?.submenu)
        typealias VC = ConcordanceViewController
        let expected: [(String, Selector)] = [
            ("History…", #selector(VC.historyTapped(_:))), ("Sort…", #selector(VC.sortTapped(_:))),
            ("Shuffle", #selector(VC.shuffleTapped(_:))), ("Sample…", #selector(VC.sampleTapped(_:))),
            ("Context…", #selector(VC.contextTapped(_:))), ("Attributes…", #selector(VC.attributesTapped(_:))),
            ("Collocations…", #selector(VC.collocationsTapped(_:))), ("Frequencies…", #selector(VC.frequenciesTapped(_:))),
            ("Dispersion", #selector(VC.dispersionTapped(_:))), ("Operations…", #selector(VC.operationsTapped(_:)))]
        for (title, action) in expected {
            let item = try #require(queryMenu.items.first { $0.title == title }, Comment(rawValue: title))
            #expect(item.action == action && item.target == nil, Comment(rawValue: title))
        }
        // The toolbar has exactly these actions (ten), no more.
        let toolbarCount = ConcordanceWindowController.groups.flatMap(\.items).count + 2
        #expect(toolbarCount == expected.count)
        let viewMenu = try #require(menu.items.first { $0.submenu?.title == "View" }?.submenu)
        #expect(viewMenu.items.contains { $0.action == #selector(NSWindow.runToolbarCustomizationPalette(_:)) })
        #expect(viewMenu.items.contains { $0.action == #selector(NSWindow.toggleToolbarShown(_:)) })
    }

    /// From the menu the sender is a menu item, not a button: the popovers must still find a view.
    @Test func popoverCommandsWorkFromTheMenu() throws {
        let controller = shownController()
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        let viewController = try #require(window.contentViewController as? ConcordanceViewController)
        typealias VC = ConcordanceViewController
        for action in [#selector(VC.sortTapped(_:)), #selector(VC.sampleTapped(_:)), #selector(VC.contextTapped(_:)),
                       #selector(VC.attributesTapped(_:)), #selector(VC.historyTapped(_:)), #selector(VC.operationsTapped(_:)),
                       #selector(VC.shuffleTapped(_:))] {
            #expect(NSApp.sendAction(action, to: viewController, from: NSMenuItem()), "\(action)")
        }
        for popoverWindow in NSApp.windows where popoverWindow !== window && popoverWindow.className.contains("Popover") { popoverWindow.close() }
    }

    @Test func theToolbarIsCustomizableAndRemembered() throws {
        let controller = shownController()
        let toolbar = try #require(controller.window?.toolbar)
        #expect(toolbar.allowsUserCustomization && toolbar.autosavesConfiguration)
    }
}
