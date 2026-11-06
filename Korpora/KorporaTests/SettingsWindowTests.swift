import Cocoa
import Testing
@testable import Korpora

/// The Settings window can be resized (it wasn't), and what benefits from
/// more room gets it.
///
/// The window has to be on screen for AppKit to lay it out at all, so each
/// test orders it behind everything else and away again.
@MainActor @Suite(.serialized) struct SettingsWindowTests {
    private func shownWindow() throws -> NSWindow {
        let window = try #require(SettingsWindowController.shared.window)
        window.orderBack(nil)
        return window
    }

    private func layOut(_ window: NSWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
    }

    /// Each pane opens at the size it was designed for, and that is the
    /// smallest the user can drag it to.
    @Test func isResizableAndEachPaneOpensAtItsDesignedSize() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        #expect(window.styleMask.contains(.resizable))
        let designed: [SettingsWindowController.Pane: NSSize] = [
            .corpora: NSSize(width: 840, height: 470),
            .appearance: NSSize(width: 460, height: 520),
            .concordance: NSSize(width: 460, height: 290),
        ]
        for pane in SettingsWindowController.Pane.allCases {
            SettingsWindowController.shared.showPane(pane)
            layOut(window)
            let size = try #require(designed[pane])
            #expect(window.contentMinSize == size, "\(pane) minimum")
            #expect(window.contentView?.frame.size == size, "\(pane) opening size")
        }
    }

    /// The Name column is the one that needs room: at the opening size it is much the widest, long names fit, and
    /// the fixed columns are no wider than their headings need.
    @Test func theNameColumnGetsMostOfTheRoomAtTheOpeningSize() throws {
        let box = try TestPando.Sandbox()
        try box.fakeIndex(named: "Czech National Corpus SYN2025", tokens: 122_251_447)
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        SettingsWindowController.shared.showPane(.corpora)
        layOut(window)
        let controller = try #require(window.contentViewController as? CorporaSettingsViewController)
        let widths = Dictionary(uniqueKeysWithValues: controller.tableView.tableColumns.map { ($0.identifier.rawValue, $0.width) })
        let name = try #require(widths["name"])
        #expect(name >= 220, "Name has \(name)")
        let others = widths.filter { $0.key != "name" }.values.reduce(0, +)
        #expect(name > others * 0.4, "Name \(name) vs the other columns together \(others)")
        let longName = NSAttributedString(string: "Czech National Corpus SYN2025", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        #expect(longName.size().width + 12 < name, "a long corpus name is not cut off")
        #expect(widths["resident"] ?? 999 <= 110, "the In Memory column is no wider than it needs")
    }

    /// A long folder path in the pane must not widen the Settings window: it is shortened instead.
    @Test func aLongFolderPathDoesNotWidenTheWindow() throws {
        let long = "/very/long/" + String(repeating: "folder-name/", count: 12) + "Corpora"
        let saved = ProcessInfo.processInfo.environment["KORPORA_CORPORA_DIRECTORY"]
        setenv("KORPORA_CORPORA_DIRECTORY", long, 1)
        defer { if let saved { setenv("KORPORA_CORPORA_DIRECTORY", saved, 1) } else { unsetenv("KORPORA_CORPORA_DIRECTORY") } }
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        SettingsWindowController.shared.showPane(.corpora)
        layOut(window)
        #expect(window.contentView?.frame.width == 840, "\(window.contentView?.frame.width ?? 0)")
    }

    /// Regression: AppKit turns a non-zero `preferredContentSize` into
    /// priority-501 width/height constraints on the pane's view, which beat
    /// the window's own size constraint (500) and pinned the pane, so the
    /// window snapped back after any resize.
    @Test func thePaneFollowsTheWindow() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        for pane in SettingsWindowController.Pane.allCases {
            SettingsWindowController.shared.showPane(pane)
            layOut(window)
            window.setContentSize(NSSize(width: 800, height: 700))
            layOut(window)
            #expect(window.contentView?.frame.size == NSSize(width: 800, height: 700), "\(pane)")
        }
    }

    /// The corpus list is the point of that pane: it gets the extra room.
    @Test func theCorpusListGrowsWithTheWindow() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        SettingsWindowController.shared.showPane(.corpora)
        layOut(window)
        let controller = try #require(window.contentViewController as? CorporaSettingsViewController)
        let list = try #require(controller.tableView.enclosingScrollView)
        let before = list.frame

        window.setContentSize(NSSize(width: 1020, height: 740))
        layOut(window)
        #expect(list.frame.height >= before.height + 250, "list went from \(before.height) to \(list.frame.height)")
        #expect(list.frame.width >= before.width + 180, "list went from \(before.width) to \(list.frame.width)")
    }

    @Test func theAppearanceListGrowsWithTheWindow() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        SettingsWindowController.shared.showPane(.appearance)
        layOut(window)
        let controller = try #require(window.contentViewController)
        let list = try #require(scrollViews(in: controller.view).last)
        let before = list.frame.height

        window.setContentSize(NSSize(width: 600, height: 720))
        layOut(window)
        #expect(list.frame.height >= before + 150, "list went from \(before) to \(list.frame.height)")
    }

    /// "Keep in Memory" was cut to "Keep in Me…". The table used "last column
    /// only" autoresizing, so at the opening size the columns plus spacing
    /// didn't fit and the last one shrank to 75 points (and, widened, took
    /// all the extra width). Now every heading fits its column at every
    /// window size, and extra width goes to the Name column alone.
    @Test func everyCorpusTableHeadingFitsItsColumn() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        SettingsWindowController.shared.showPane(.corpora)
        layOut(window)
        let controller = try #require(window.contentViewController as? CorporaSettingsViewController)
        let table = controller.tableView

        /// The heading text plus room for the header cell's own padding and
        /// the ellipsis it would otherwise fall back to.
        func check(_ label: String) {
            for column in table.tableColumns {
                let needed = column.headerCell.attributedStringValue.size().width + 30
                #expect(column.width >= needed, "\(label): \u{201C}\(column.title)\u{201D} needs \(needed), has \(column.width)")
            }
        }
        func widths() -> [CGFloat] { table.tableColumns.map(\.width) }

        check("opening size")
        let opening = widths()
        window.setContentSize(NSSize(width: 1020, height: 500))
        layOut(window)
        check("wider")
        let wider = widths()
        #expect(wider[0] > opening[0] + 150, "Name takes the extra width: \(opening[0]) -> \(wider[0])")
        #expect(Array(wider.dropFirst()) == Array(opening.dropFirst()), "the other columns keep their widths")

        window.setContentSize(controller.view.frame.size)
        window.setContentSize(NSSize(width: 840, height: 470))
        layOut(window)
        check("back at the minimum")
        #expect(widths() == opening, "same layout at the same size")
    }

    /// The panes that are just a form (Concordance) or a form plus a list
    /// (Appearance) keep their content in a centered column of the designed
    /// width instead of leaving it in a corner of a bigger window.
    @Test func formPanesStayCenteredWhenTheWindowIsWider() throws {
        let window = try shownWindow()
        defer { window.orderOut(nil) }
        for (pane, width) in [(SettingsWindowController.Pane.concordance, CGFloat(460)),
                              (.appearance, CGFloat(460))] {
            SettingsWindowController.shared.showPane(pane)
            layOut(window)
            window.setContentSize(NSSize(width: 900, height: 700))
            layOut(window)
            let controller = try #require(window.contentViewController)
            let column = try #require(controller.view.subviews.first, "\(pane)")
            #expect(column.frame.width == width, "\(pane) column width")
            #expect(abs(column.frame.midX - controller.view.bounds.midX) < 1, "\(pane) is centered: \(column.frame)")
            #expect(column.frame.minY == 0 && column.frame.height == controller.view.bounds.height, "\(pane) full height")
        }
    }
}

/// The Settings window reopens as it was left: the pane last used, and the size the user gave each pane.
@MainActor @Suite(.serialized) struct SettingsWindowMemoryTests {
    private func freshMemory() -> SettingsWindowMemory {
        SettingsWindowMemory(defaults: UserDefaults(suiteName: "SettingsWindowMemoryTests-\(UUID().uuidString)")!)
    }

    @Test func rememberedValuesComeBack() {
        let memory = freshMemory()
        #expect(memory.lastPane == nil && memory.topLeft == nil && memory.size(for: .corpora) == nil)
        memory.lastPane = .appearance
        memory.topLeft = NSPoint(x: 120, y: 700)
        memory.setSize(NSSize(width: 900, height: 600), for: .corpora)
        #expect(memory.lastPane == .appearance)
        #expect(memory.topLeft == NSPoint(x: 120, y: 700))
        #expect(memory.size(for: .corpora) == NSSize(width: 900, height: 600))
        #expect(memory.size(for: .appearance) == nil, "sizes are kept per pane")
    }

    @Test func aSavedSizeIsClampedToWhatTheSizeCanBe() {
        let designed = NSSize(width: 680, height: 440)
        let screen = NSSize(width: 1440, height: 900)
        #expect(SettingsWindowMemory.restoredSize(saved: nil, designed: designed, screen: screen) == designed)
        #expect(SettingsWindowMemory.restoredSize(saved: NSSize(width: 900, height: 600), designed: designed, screen: screen)
                == NSSize(width: 900, height: 600))
        #expect(SettingsWindowMemory.restoredSize(saved: NSSize(width: 300, height: 200), designed: designed, screen: screen)
                == designed, "never below the size the pane is laid out for")
        let huge = SettingsWindowMemory.restoredSize(saved: NSSize(width: 9000, height: 9000), designed: designed, screen: screen)
        #expect(huge.width <= 1440 && huge.height <= 900, "never bigger than the screen: \(huge)")
    }

    @Test func theWindowReopensOnTheLastPaneAtTheSizeTheUserGaveIt() throws {
        let controller = SettingsWindowController.shared
        let saved = controller.memory
        controller.memory = freshMemory()
        defer { controller.memory = saved; controller.window?.orderOut(nil) }
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)

        controller.showPane(.corpora)
        let designed = try #require(window.contentView?.frame.size)
        window.setContentSize(NSSize(width: designed.width + 220, height: designed.height + 160))
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        let given = try #require(window.contentView?.frame.size)

        controller.showPane(.appearance)
        #expect(controller.memory.lastPane == .appearance)
        controller.showPane(.corpora)
        #expect(window.contentView?.frame.size == given, "the corpora pane got its size back")
        #expect(window.contentMinSize == designed, "the minimum is still the designed size")

        // The other pane is untouched by it.
        controller.showPane(.concordance)
        #expect(window.contentView?.frame.size == window.contentMinSize)
        #expect(controller.memory.lastPane == .concordance)
    }

    @Test func switchingPanesKeepsTheTopLeftCornerInPlace() throws {
        let controller = SettingsWindowController.shared
        let saved = controller.memory
        controller.memory = freshMemory()
        defer { controller.memory = saved; controller.window?.orderOut(nil) }
        let window = try #require(controller.window)
        controller.showPane(.corpora)
        window.makeKeyAndOrderFront(nil)
        let top = window.frame.maxY, left = window.frame.minX
        controller.showPane(.concordance)
        #expect(window.frame.maxY == top && window.frame.minX == left, "the pane changed under the same top-left corner")
    }

    @Test func testsDoNotWriteIntoTheAppsOwnPreferences() {
        #expect(SettingsWindowMemory().defaults !== UserDefaults.standard)
    }
}
