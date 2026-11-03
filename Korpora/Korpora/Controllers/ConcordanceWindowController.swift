import Cocoa

/// One window per `ConcordanceDocument`. Relies on AppKit's automatic native
/// window tabbing (the default for document-based apps) so several
/// concordances can sit side by side as tabs - no custom tab UI needed.
final class ConcordanceWindowController: NSWindowController, NSToolbarDelegate {
    enum ItemID {
        static let history = NSToolbarItem.Identifier("history")
        static let sort = NSToolbarItem.Identifier("sort")
        static let shuffle = NSToolbarItem.Identifier("shuffle")
        static let sample = NSToolbarItem.Identifier("sample")
        static let context = NSToolbarItem.Identifier("context")
        static let attributes = NSToolbarItem.Identifier("attributes")
        static let collocations = NSToolbarItem.Identifier("collocations")
        static let frequencies = NSToolbarItem.Identifier("frequencies")
        static let dispersion = NSToolbarItem.Identifier("dispersion")
        static let operations = NSToolbarItem.Identifier("operations")

        // Groups: items that belong together share one background (and, with labels shown, stay one
        // control instead of a row of separate bubbles).
        static let resultGroup = NSToolbarItem.Identifier("group.result")
        static let displayGroup = NSToolbarItem.Identifier("group.display")
        static let analysisGroup = NSToolbarItem.Identifier("group.analysis")
    }

    /// The toolbar's logical groups, by function (the HIG: group items by function and frequency of use,
    /// at most three groups, fixed space between them):
    /// - what is done to the result (sort, shuffle, sample),
    /// - how it is shown (context, attributes),
    /// - what is learned from it (collocations, frequencies, dispersion).
    /// History (the query) and Operations (what has been applied) stand on their own at the two ends.
    static let groups: [(id: NSToolbarItem.Identifier, title: String, items: [NSToolbarItem.Identifier])] = [
        (ItemID.resultGroup, "Result", [ItemID.sort, ItemID.shuffle, ItemID.sample]),
        (ItemID.displayGroup, "Display", [ItemID.context, ItemID.attributes]),
        (ItemID.analysisGroup, "Analysis", [ItemID.collocations, ItemID.frequencies, ItemID.dispersion]),
    ]

    private var sortButton: NSButton?
    private var shuffleButton: NSButton?
    private var sampleButton: NSButton?
    private var contextButton: NSButton?

    convenience init(document: ConcordanceDocument) {
        let viewController = ConcordanceViewController(document: document)
        let window = NSWindow(contentViewController: viewController)
        window.setContentSize(NSSize(width: 820, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .preferred
        // ConcordanceDocument's own data(ofType:)/read(from:ofType:) is the
        // real reopen-a-concordance mechanism (see docs/project-plan.md's
        // NSDocument model) - the system's separate crash/relaunch window-restoration
        // path is redundant here and, if it ever finds stale state, can
        // silently swallow a launch (no window, no error).
        window.isRestorable = false
        self.init(window: window)
        viewController.windowController = self

        let toolbar = NSToolbar(identifier: "ConcordanceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.history, .space, ItemID.resultGroup, .space, ItemID.displayGroup, .space, ItemID.analysisGroup,
         .flexibleSpace, ItemID.operations]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let group = Self.groups.first(where: { $0.id == identifier }) {
            let item = NSToolbarItemGroup(itemIdentifier: identifier)
            // The items keep their own labels (none on the group), and stay one expanded control.
            item.subitems = group.items.compactMap { makeLeafItem($0) }
            item.selectionMode = .momentary
            item.controlRepresentation = .expanded
            item.paletteLabel = group.title
            return item
        }
        return makeLeafItem(identifier)
    }

    private func makeLeafItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let viewController = window?.contentViewController as? ConcordanceViewController else { return nil }
        switch identifier {
        case ItemID.history:
            // Not tracked in a stored property/`updateToolbarState` -
            // running a different query is always allowed regardless of
            // line groups (`ConcordanceDocument.runQuery` resets the whole
            // operation chain itself, same as typing into the query bar).
            let button = makeButton(
                symbol: "clock.arrow.circlepath", label: "History",
                tooltip: "Recall a recently run query", target: viewController,
                action: #selector(ConcordanceViewController.historyTapped(_:)))
            return makeItem(identifier, label: "History", view: button)
        case ItemID.sort:
            let button = makeButton(
                symbol: "arrow.up.arrow.down", label: "Sort",
                tooltip: "Sort concordance lines", target: viewController,
                action: #selector(ConcordanceViewController.sortTapped(_:)))
            sortButton = button
            return makeItem(identifier, label: "Sort", view: button)
        case ItemID.shuffle:
            let button = makeButton(
                symbol: "shuffle", label: "Shuffle",
                tooltip: "Randomize line order", target: viewController,
                action: #selector(ConcordanceViewController.shuffleTapped(_:)))
            shuffleButton = button
            return makeItem(identifier, label: "Shuffle", view: button)
        case ItemID.sample:
            let button = makeButton(
                symbol: "number", label: "Sample",
                tooltip: "Reduce to a random sample of lines", target: viewController,
                action: #selector(ConcordanceViewController.sampleTapped(_:)))
            sampleButton = button
            return makeItem(identifier, label: "Sample", view: button)
        case ItemID.context:
            // Not tracked in `updateToolbarState`: unlike sort/shuffle/sample, widening
            // context is a display setting (see `ConcordanceDocument.setContext`), not
            // an operation on the result, so it never needs to disable when line
            // groups exist.
            let button = makeButton(
                symbol: "arrow.left.and.right", label: "Context",
                tooltip: "Adjust how much left/right context is shown", target: viewController,
                action: #selector(ConcordanceViewController.contextTapped(_:)))
            contextButton = button
            return makeItem(identifier, label: "Context", view: button)
        case ItemID.attributes:
            // Not tracked in a stored property/`updateToolbarState` - same
            // "pure display setting" reasoning as Context above.
            let button = makeButton(
                symbol: "textformat", label: "Attributes",
                tooltip: "Show additional attributes (e.g. lemma, tag) inline or on hover", target: viewController,
                action: #selector(ConcordanceViewController.attributesTapped(_:)))
            return makeItem(identifier, label: "Attributes", view: button)
        case ItemID.collocations:
            let button = makeButton(
                symbol: "arrow.left.arrow.right", label: "Collocations",
                tooltip: "Find words that co-occur with the search term", target: viewController,
                action: #selector(ConcordanceViewController.collocationsTapped(_:)))
            return makeItem(identifier, label: "Collocations", view: button)
        case ItemID.frequencies:
            let button = makeButton(
                symbol: "chart.bar", label: "Frequencies",
                tooltip: "Show a frequency distribution for an attribute", target: viewController,
                action: #selector(ConcordanceViewController.frequenciesTapped(_:)))
            return makeItem(identifier, label: "Frequencies", view: button)
        case ItemID.dispersion:
            let button = makeButton(
                symbol: "chart.bar.xaxis", label: "Dispersion",
                tooltip: "Show where the hits fall across the corpus", target: viewController,
                action: #selector(ConcordanceViewController.dispersionTapped(_:)))
            return makeItem(identifier, label: "Dispersion", view: button)
        case ItemID.operations:
            // Icon carried over from the old standalone "Clear Groups"
            // button - merged into this one, since both are fundamentally
            // "review and cancel active operations" (see
            // OperationsPopoverController).
            let button = makeButton(
                symbol: "xmark.circle", label: "Operations",
                tooltip: "Review and remove active sort/line-group operations", target: viewController,
                action: #selector(ConcordanceViewController.operationsTapped(_:)))
            return makeItem(identifier, label: "Operations", view: button)
        default:
            return nil
        }
    }

    private func makeButton(symbol: String, label: String, tooltip: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
            target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        return button
    }

    private func makeItem(_ identifier: NSToolbarItem.Identifier, label: String, view: NSView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = view
        return item
    }

    /// Custom-view toolbar items don't auto-validate - called from
    /// `ConcordanceViewController.refresh()` instead, mirroring KonText's own
    /// mutual-exclusion rule (line groups vs. sort/shuffle/sample).
    /// The Operations button stays enabled regardless - reviewing/removing
    /// *existing* operations (including bulk-clearing line groups) doesn't
    /// conflict with an active line-group view the way starting a *new*
    /// sort/filter/shuffle/sample would.
    func updateToolbarState(hasLineGroups: Bool) {
        sortButton?.isEnabled = !hasLineGroups
        shuffleButton?.isEnabled = !hasLineGroups
        sampleButton?.isEnabled = !hasLineGroups
    }
}

/// `NSSegmentedCell.setToolTip(_:forSegment:)` exists but Apple's own docs
/// say plainly "Tooltips are currently not displayed" - confirmed true
/// here too (a single whole-control `.toolTip` showed the same combined
/// text regardless of which segment was hovered, which read as confusing
/// once there were two segments with distinct meanings). Tracks the mouse
/// instead and swaps the control's own `toolTip` for whichever segment
/// it's over - same technique already used for per-token KWIC tooltips
/// (see `KWICCellView`), just applied to a control that's created once
/// and kept for the toolbar's lifetime rather than a table cell that's
/// constantly recreated/reused, which was the likely cause of that
/// mechanism's own flakiness there.
private final class PerSegmentToolTipSegmentedControl: NSSegmentedControl {
    var segmentToolTips: [String] = []
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolTip(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateToolTip(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        toolTip = nil
    }

    private func updateToolTip(for event: NSEvent) {
        guard segmentCount > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let segmentWidth = bounds.width / CGFloat(segmentCount)
        let index = min(max(Int(point.x / segmentWidth), 0), segmentCount - 1)
        toolTip = segmentToolTips.indices.contains(index) ? segmentToolTips[index] : nil
    }
}
