import Cocoa

/// At launch AppKit opens an untitled concordance (the New Concordance sheet) before the windows of the last session
/// have come back, so a restored session would show an extra empty window with a sheet over it. The first sheet of a
/// launch waits until the system has finished putting the windows back; if a concordance came back, the empty one is
/// not needed and closes. A new concordance the user asks for later (⌘N) is not held back.
@MainActor
enum LaunchRestoration {
    private static var finished = false
    private static var pending: [(Bool) -> Void] = []
    private static var observer: NSObjectProtocol?

    /// Call once at launch. `timeout` is the longest the first sheet waits, whatever the system says.
    static func begin(timeout: TimeInterval = 2) {
        finished = false
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishRestoringWindowsNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { finish() }
        }
        // A timer on the common modes, like every wait around the launch and the quit.
        RunLoop.main.add(Timer(timeInterval: timeout, repeats: false) { _ in MainActor.assumeIsolated { finish() } }, forMode: .common)
    }

    /// Runs `work` on the main thread once the restoration is over (in the next turn when it already is). `work` is
    /// told whether it had to wait, that is, whether it is part of the launch.
    static func afterRestoration(_ work: @escaping (_ duringLaunch: Bool) -> Void) {
        if finished {
            DispatchQueue.main.async { work(false) }
        } else {
            pending.append(work)
        }
    }

    static func finish() {
        guard !finished else { return }
        finished = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let work = pending
        pending = []
        for item in work { item(true) }
    }
}
