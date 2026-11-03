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

    /// The state goes to the items the toolbar holds, even when the delegate has built other copies
    /// since (the toolbar does that on a first launch and when customizing).
    @Test func lineGroupsStillDisableSortShuffleAndSampleInsideTheirGroup() throws {
        let controller = shownController()
        let toolbar = try #require(controller.window?.toolbar)
        let ItemID = ConcordanceWindowController.ItemID.self
        for _ in 0..<2 {  // stray copies, as built for a palette or a second pass
            _ = controller.toolbar(toolbar, itemForItemIdentifier: ItemID.resultGroup, willBeInsertedIntoToolbar: true)
        }
        func group(_ id: NSToolbarItem.Identifier) throws -> NSToolbarItemGroup {
            try #require(toolbar.items.first { $0.itemIdentifier == id } as? NSToolbarItemGroup)
        }
        let result = try group(ItemID.resultGroup), display = try group(ItemID.displayGroup)
        #expect(result.subitems.count == 3 && result.subitems.allSatisfy { $0.isEnabled })
        controller.updateToolbarState(hasLineGroups: true)
        #expect(result.subitems.allSatisfy { !$0.isEnabled })
        #expect(display.subitems.allSatisfy { $0.isEnabled }, "Context and Attributes are display settings, never off")
        controller.updateToolbarState(hasLineGroups: false)
        #expect(result.subitems.allSatisfy { $0.isEnabled })
    }

    /// An item built after line groups appeared (the toolbar rebuilding itself) starts disabled.
    @Test func aGroupBuiltWhileLineGroupsExistStartsDisabled() throws {
        let controller = shownController()
        let toolbar = try #require(controller.window?.toolbar)
        controller.updateToolbarState(hasLineGroups: true)
        let built = try #require(controller.toolbar(toolbar, itemForItemIdentifier: ConcordanceWindowController.ItemID.resultGroup,
                                                    willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup)
        #expect(built.subitems.allSatisfy { !$0.isEnabled })
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

    /// The toolbar validates its items on every event, which once switched the disabled segments
    /// back on: checked on the real segmented control, after a validation pass.
    @Test func disabledSegmentsStayDisabledAfterTheToolbarValidates() throws {
        let controller = shownController()
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        func segmented(_ view: NSView) -> [NSSegmentedControl] { ((view as? NSSegmentedControl).map { [$0] } ?? []) + view.subviews.flatMap(segmented) }
        let root = try #require(window.contentView?.superview)
        let controls = segmented(root).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let result = try #require(controls.first), display = try #require(controls.dropFirst().first)
        #expect(result.segmentCount == 3 && display.segmentCount == 2)
        controller.updateToolbarState(hasLineGroups: true)
        window.toolbar?.validateVisibleItems()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        #expect((0..<3).allSatisfy { !result.isEnabled(forSegment: $0) }, "Sort, Shuffle, Sample are off")
        #expect((0..<2).allSatisfy { display.isEnabled(forSegment: $0) }, "Context and Attributes stay on")
        controller.updateToolbarState(hasLineGroups: false)
        window.toolbar?.validateVisibleItems()
        #expect((0..<3).allSatisfy { result.isEnabled(forSegment: $0) })
    }
}
