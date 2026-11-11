import Cocoa

/// At launch AppKit opens an untitled concordance (the New Concordance sheet) of its own, and the windows of the last
/// session come back a moment later, so a restored session would show an extra empty window with a sheet over it.
/// The system's own signals for "restoration is done" proved unreliable, so the rule is a plain one: a concordance
/// the app opens by itself in the first seconds of a launch waits a short grace period, and if a concordance of the
/// last session is there by then, the empty one closes. One the user asked for (⌘N, File > New) is never touched.
@MainActor
enum LaunchRestoration {
    /// The first seconds of a launch, in which an untitled concordance is the app's own doing.
    static var launchWindow: TimeInterval = 4
    /// How long such a concordance waits for the restored ones to arrive.
    static var grace: TimeInterval = 1
    private static var startedAt = Date()
    /// Set by `KorporaDocumentController.newDocument(_:)`, taken by the next concordance that asks.
    static var userRequestedNew = false

    /// Call once at launch.
    static func begin() {
        startedAt = Date()
        userRequestedNew = false
    }

    /// Runs `work` on the main thread: after the grace period, told `true`, for a concordance the app opened by
    /// itself at launch; in the next turn, told `false`, for any other.
    static func afterRestoration(_ work: @escaping (_ duringLaunch: Bool) -> Void) {
        let askedFor = userRequestedNew
        userRequestedNew = false
        if !askedFor, Date().timeIntervalSince(startedAt) < launchWindow {
            // A timer on the common modes, like every wait around the launch and the quit.
            RunLoop.main.add(Timer(timeInterval: grace, repeats: false) { _ in
                MainActor.assumeIsolated { work(true) }
            }, forMode: .common)
        } else {
            DispatchQueue.main.async { work(false) }
        }
    }
}
