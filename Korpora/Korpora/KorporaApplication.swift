import Cocoa

/// The application object. A quit goes through here first (⌘Q, the Dock's Quit, a Sparkle relaunch, a log-out).
///
/// AppKit refuses to quit while a sheet is open ("App termination blocked by modal sheet") and says nothing; the app
/// always has one at launch (the New Concordance sheet). The sheets are closed first, and the quit goes on in the next
/// turn of the run loop. Everything else about keeping the concordances is AppKit's own document autosave and window
/// restoration (docs/project-plan.md, "Document persistence model").
final class KorporaApplication: NSApplication {
    private var isPreparingToQuit = false

    override func terminate(_ sender: Any?) {
        guard !isPreparingToQuit else { return }
        isPreparingToQuit = true
        AppDelegate.endAllSheets()
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.isPreparingToQuit = false
            self.terminateByAppKit(sender)
        }
    }

    /// AppKit's own quit, which also writes the system's saved window state and waits for the system to say it is
    /// done; scripted runs here saw that wait never end (every thread idle, the main one waiting on a reply). After
    /// `quitWatchdogSeconds` the app quits anyway: its documents have been autosaved by then.
    private func terminateByAppKit(_ sender: Any?) {
        startQuitWatchdog()
        super.terminate(sender)
    }

    static let quitWatchdogSeconds: TimeInterval = 10
    private var watchdog: Timer?

    func startQuitWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: Self.quitWatchdogSeconds, repeats: false) { _ in
            NSLog("Korpora: the quit did not finish in \(Int(Self.quitWatchdogSeconds)) s; quitting")
            exit(0)
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func stopQuitWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }
}
