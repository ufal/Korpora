import Cocoa

/// The classic macOS multi-pane Settings/Preferences window (`Cmd-,`): a
/// `.preference`-styled toolbar switching a single content view controller,
/// same pattern System Settings and most Mac apps have used for decades.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// What the window remembers between openings: the pane last used, where the window was, and the size
    /// the user gave each pane (the Human Interface Guidelines: a settings window reopens as it was left).
    var memory = SettingsWindowMemory()
    private(set) var currentPane: Pane = .corpora

    enum Pane: String, CaseIterable {
        case corpora, appearance, concordance

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .concordance: return "Concordance"
            case .corpora: return "Corpora"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "textformat"
            case .concordance: return "text.alignleft"
            case .corpora: return "internaldrive"
            }
        }

        var identifier: NSToolbarItem.Identifier { .init(rawValue) }

        func makeViewController() -> NSViewController {
            switch self {
            case .appearance: return AppearanceSettingsViewController()
            case .concordance: return ConcordanceSettingsViewController()
            case .corpora: return CorporaSettingsViewController()
            }
        }
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        self.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        showPane(memory.lastPane ?? .corpora)
        // Where it was last left, if that is still on a screen; else centred (as above).
        if let topLeft = memory.topLeft, NSScreen.screens.contains(where: { $0.visibleFrame.contains(topLeft) }) {
            window.setFrameTopLeftPoint(topLeft)
        }
    }

    /// Opens the Settings window on `pane`, in front: what other parts of the app call to send the user there
    /// (`showPane` alone only switches what is in the window, which may not even be on screen).
    func show(_ pane: Pane) {
        showPane(pane)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Each pane is laid out for a minimum size (its `preferredContentSize`)
    /// and is free to grow from there: the Corpora and Appearance lists take
    /// the extra height, the forms just get more room. Switching panes
    /// resizes the window to the new pane's own size, as preference windows
    /// do.
    func showPane(_ pane: Pane) {
        guard let window else { return }
        window.title = pane.title
        let controller = pane.makeViewController()
        // The size the pane was laid out for is its minimum and the size to
        // start at; it's taken from `preferredContentSize` and then cleared
        // *before* the pane is installed. AppKit turns a non-zero
        // `preferredContentSize` into constraints on the pane's view at
        // priority 501, one above the window's own size constraint, so the
        // window would snap back to that size after every resize.
        _ = controller.view  // loads it; the panes set their size in `loadView`
        let designedSize = controller.preferredContentSize
        controller.preferredContentSize = .zero
        // Switching panes keeps the window's top-left corner where it is (resizing alone would keep the bottom-left).
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.contentViewController = controller
        window.contentMinSize = designedSize
        // The size the user gave this pane last time, never smaller than it is designed for or bigger than the screen.
        window.setContentSize(SettingsWindowMemory.restoredSize(
            saved: memory.size(for: pane), designed: designedSize,
            screen: (window.screen ?? NSScreen.main)?.visibleFrame.size))
        if window.isVisible { window.setFrameTopLeftPoint(topLeft) }
        window.toolbar?.selectedItemIdentifier = pane.identifier
        currentPane = pane
        memory.lastPane = pane
    }

    // MARK: Remembering the window

    /// The user finished dragging the window's edge: that is the size this pane gets from now on.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let size = window?.contentView?.frame.size else { return }
        memory.setSize(size, for: currentPane)
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame, window?.isVisible == true else { return }
        memory.topLeft = NSPoint(x: frame.minX, y: frame.maxY)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
        showPane(pane)
    }
}

/// The Settings window's memory, in `UserDefaults`: the pane last shown, the window's top-left corner, and a
/// size per pane (each pane is laid out for its own content, so the sizes are kept apart).
struct SettingsWindowMemory {
    /// The app's preferences - except under test (which runs inside the app), so tests never overwrite what
    /// the user has set.
    static var appDefaults: UserDefaults {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? UserDefaults(suiteName: "KorporaTests.SettingsWindowMemory")! : .standard
    }

    var defaults: UserDefaults = SettingsWindowMemory.appDefaults

    private enum Key {
        static let pane = "settingsLastPane"
        static let topLeft = "settingsWindowTopLeft"
        static func size(_ pane: SettingsWindowController.Pane) -> String { "settingsPaneSize.\(pane.rawValue)" }
    }

    var lastPane: SettingsWindowController.Pane? {
        get { defaults.string(forKey: Key.pane).flatMap(SettingsWindowController.Pane.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Key.pane) }
    }

    var topLeft: NSPoint? {
        get {
            guard let numbers = defaults.array(forKey: Key.topLeft) as? [Double], numbers.count == 2 else { return nil }
            return NSPoint(x: numbers[0], y: numbers[1])
        }
        nonmutating set { defaults.set(newValue.map { [Double($0.x), Double($0.y)] }, forKey: Key.topLeft) }
    }

    func size(for pane: SettingsWindowController.Pane) -> NSSize? {
        guard let numbers = defaults.array(forKey: Key.size(pane)) as? [Double], numbers.count == 2,
              numbers[0] > 0, numbers[1] > 0 else { return nil }
        return NSSize(width: numbers[0], height: numbers[1])
    }

    func setSize(_ size: NSSize, for pane: SettingsWindowController.Pane) {
        defaults.set([Double(size.width), Double(size.height)], forKey: Key.size(pane))
    }

    /// The saved size, but never below the pane's designed (minimum) size and never beyond the screen it is on.
    static func restoredSize(saved: NSSize?, designed: NSSize, screen: NSSize?) -> NSSize {
        guard var size = saved else { return designed }
        size.width = max(size.width, designed.width)
        size.height = max(size.height, designed.height)
        if let screen {
            size.width = max(min(size.width, screen.width), designed.width)
            size.height = max(min(size.height, screen.height - 80), designed.height)
        }
        return size
    }
}
