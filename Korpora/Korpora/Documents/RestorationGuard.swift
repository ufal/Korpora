import Foundation

/// Protects the launch from a bad saved window state. An early version of the app had window restoration switched
/// off, because stale state once made a launch fail silently (no window, no error) after repeated force-quits
/// (docs/project-plan.md, Phase 0). The system's saved state lives in a folder the app can delete: this notes when a
/// launch starts, and when it has got as far as showing windows (or quits cleanly); a launch that finds the note of
/// an unfinished one deletes the saved state before AppKit reads it.
enum RestorationGuard {
    static let key = "launchStartedAt"

    /// `~/Library/Saved Application State/<bundle id>.savedState`: the system's own record of the open windows.
    static func savedStateFolder(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL? {
        guard let bundleIdentifier,
              let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        return library.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState", isDirectory: true)
    }

    /// Call first thing at launch. Returns whether the saved state of an unfinished launch was dropped.
    @discardableResult
    static func beginLaunch(defaults: UserDefaults = .standard, savedState: URL? = savedStateFolder(), now: Date = Date()) -> Bool {
        var dropped = false
        if defaults.object(forKey: key) != nil {
            if let savedState, FileManager.default.fileExists(atPath: savedState.path) {
                try? FileManager.default.removeItem(at: savedState)
                dropped = true
            }
            NSLog("Korpora: the last launch did not finish; the saved windows were dropped")
        }
        defaults.set(now.timeIntervalSince1970, forKey: key)
        return dropped
    }

    /// Call when the launch has worked (windows are up) and on a clean quit.
    static func finishLaunch(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
