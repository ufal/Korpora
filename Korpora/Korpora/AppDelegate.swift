import Cocoa
import KorporaEngine
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Updates (docs/sparkle.md). A Debug build, which is what runs from Xcode, never checks by itself (it
    /// would offer to replace the build being tried); "Check for Updates..." still works there.
    private lazy var updaterController: SPUStandardUpdaterController = {
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        return SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    #if DEBUG
    private var updaterStarted = false
    #endif

    @objc func checkForUpdates(_ sender: Any?) {
        #if DEBUG
        if !updaterStarted { updaterStarted = true; updaterController.startUpdater() }
        #endif
        updaterController.checkForUpdates(sender)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        _ = updaterController   // starts the scheduled checks in a release build
        AppSettings.shared.applyAppearance()
        AppSettings.shared.applyCorporaDirectory()  // before anything looks for a corpus
        // Early versions hid some folders next to the corpora; make them visible (nothing is deleted).
        if CorpusLibrary.baseDirectoryIsAvailable { CorpusLibrary.makeHiddenFoldersVisible(in: CorpusLibrary.baseDirectory) }
        CorpusResidencyManager.shared.start()
        // An app launched via Xcode's debugger can appear frontmost and
        // accept clicks/keyboard input while not being *fully* activated
        // from the window server's perspective - `.activeInKeyWindow`
        // NSTrackingAreas (used for the per-token KWIC hover tooltips and
        // the toolbar button tooltips) silently didn't fire until a real
        // Cmd-Tab away and back, even after clicking directly inside the
        // window (confirmed via manual testing, 2026-09-07). Explicitly
        // activating on launch is the standard fix for this exact class of
        // debug-launch quirk.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    /// The app must be closable at any time - by the user, by a script, by
    /// the system at logout/shutdown - with no alert and nothing left
    /// pending. `ConcordanceDocument.isDocumentEdited` already reports false
    /// unconditionally (concordances are disposable scratch state, not
    /// files the user must keep or discard - see docs/project-plan.md's
    /// "Document persistence model" note), so AppKit's default unsaved-
    /// document review has nothing to prompt about - but this makes that
    /// guarantee explicit and unconditional rather than a side effect of
    /// document state, so it can't regress if that state ever changes
    /// without this being revisited too. Revisit both together per the
    /// pre-release persistence TODO in the project plan.
    ///
    /// One deliberate exception: a running corpus import (see
    /// `ActiveImportTracker`) can represent hours of compile work on a real
    /// corpus - quitting through it silently, the same way every other
    /// window does, would be a much worse surprise than one confirmation
    /// dialog. `CorpusImportSheetController` already cancels its own import
    /// (terminating the `pando-index` subprocess cleanly) on
    /// `willTerminateNotification` regardless of the answer here - this
    /// alert only decides whether that's allowed to happen at all.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ActiveImportTracker.shared.isImporting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A corpus import is in progress"
        alert.informativeText = "Quitting now will stop the compile. It can’t be resumed - you’ll need to start over."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Korpora", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updatesItem = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updatesItem.target = self
        appMenu.addItem(updatesItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Korpora", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Korpora", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        main.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Concordance", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        // Target is nil (resolved via the responder chain, same as the
        // items above) - only `ConcordanceViewController` implements this
        // selector, so AppKit's standard menu validation automatically
        // disables the item whenever no concordance window is key.
        fileMenu.addItem(withTitle: "Export Concordance…", action: #selector(ConcordanceViewController.exportConcordance(_:)), keyEquivalent: "e")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(ConcordanceViewController.printWindowContents(_:)), keyEquivalent: "p")

        let editMenuItem = NSMenuItem()
        main.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // \u{2318}. is the classic Mac "stop what you're doing"; enabled only while
        // the frontmost concordance window is searching.
        let queryMenuItem = NSMenuItem()
        main.addItem(queryMenuItem)
        let queryMenu = NSMenu(title: "Query")
        queryMenuItem.submenu = queryMenu
        // Every toolbar action is also a command here (HIG: toolbar items must be reachable from the menu bar).
        typealias VC = ConcordanceViewController
        queryMenu.addItem(withTitle: "History…", action: #selector(VC.historyTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(.separator())
        queryMenu.addItem(withTitle: "Sort…", action: #selector(VC.sortTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(withTitle: "Shuffle", action: #selector(VC.shuffleTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(withTitle: "Sample…", action: #selector(VC.sampleTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(.separator())
        queryMenu.addItem(withTitle: "Context…", action: #selector(VC.contextTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(withTitle: "Attributes…", action: #selector(VC.attributesTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(.separator())
        queryMenu.addItem(withTitle: "Collocations…", action: #selector(VC.collocationsTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(withTitle: "Frequencies…", action: #selector(VC.frequenciesTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(withTitle: "Dispersion", action: #selector(VC.dispersionTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(.separator())
        queryMenu.addItem(withTitle: "Operations…", action: #selector(VC.operationsTapped(_:)), keyEquivalent: "")
        queryMenu.addItem(.separator())
        queryMenu.addItem(withTitle: "Cancel Search", action: #selector(ConcordanceViewController.cancelSearch(_:)), keyEquivalent: ".")

        let viewMenuItem = NSMenuItem()
        main.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Hide Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t").keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: "Customize Toolbar…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")

        let windowMenuItem = NSMenuItem()
        main.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return main
    }
}
