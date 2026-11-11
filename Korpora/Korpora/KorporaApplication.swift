import Cocoa

/// The application object. A quit goes through here first (⌘Q, the Dock's Quit, a Sparkle relaunch, a log-out), and
/// two things have to happen before AppKit starts its own sequence:
///
/// 1. AppKit refuses to quit while a sheet is open ("App termination blocked by modal sheet") and says nothing; the
///    app always has one at launch (the New Concordance sheet). The sheets are closed first.
/// 2. AppKit's sequence closes every untitled document that says it has no edits before it asks the app delegate
///    anything, so an untitled concordance would be gone at the next launch. Each concordance with a query writes
///    its draft, and says it is edited while the quit goes on (`ConcordanceDocument.isQuitting`); one with no query
///    (a New Concordance sheet nobody answered) has nothing to resume and is closed.
///
/// Closing a window instead discards its concordance (and its draft). docs/project-plan.md, "Document persistence
/// model".
final class KorporaApplication: NSApplication {
    private var isPreparingToQuit = false

    override func terminate(_ sender: Any?) {
        guard !isPreparingToQuit else { return }
        isPreparingToQuit = true
        let hadSheets = AppDelegate.endAllSheets()
        // The next turn of the run loop: the sheets are gone by then.
        _ = hadSheets
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.prepareToQuit {
                self.isPreparingToQuit = false
                self.terminateByAppKit(sender)
            }
        }
    }

    /// AppKit's own quit, which comes after ours. It first writes the system's saved window state and waits for the
    /// system to say it is done; scripted runs here saw that wait never end (every thread idle, the main one waiting
    /// on a reply). The drafts are written by now, so after `quitWatchdogSeconds` the app quits anyway.
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

    private func prepareToQuit(then proceed: @escaping () -> Void) {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? ConcordanceDocument }
        for document in documents where document.initialQuery.isEmpty { document.close() }
        let withQuery = documents.filter { !$0.initialQuery.isEmpty }
        guard !withQuery.isEmpty else { proceed(); return }
        ConcordanceDocument.isQuitting = true
        var remaining = withQuery.count
        var proceeded = false
        func go() {
            guard !proceeded else { return }
            proceeded = true
            proceed()
        }
        for document in withQuery {
            document.writeDraft {
                remaining -= 1
                if remaining == 0 { go() }
            }
        }
        // Never keep the user waiting: quit after 3 seconds whatever happens (a timer on the common modes).
        RunLoop.main.add(Timer(timeInterval: 3, repeats: false) { _ in go() }, forMode: .common)
    }

    /// The quit was cancelled (an import is running and the user said no): documents are not about to go.
    func quitWasCancelled() {
        stopQuitWatchdog()
        ConcordanceDocument.isQuitting = false
    }
}
