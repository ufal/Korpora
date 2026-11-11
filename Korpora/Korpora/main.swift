import Cocoa

// Before anything reads UserDefaults: carry settings over from the
// pre-release bundle id (see LegacyDefaultsMigration).
LegacyDefaultsMigration.runIfNeeded()

// If the last launch never got as far as showing windows (it hung or crashed while the system was putting the
// saved windows back), drop what was saved, so one bad state can't make every launch fail (docs/project-plan.md,
// "Document persistence model"). Before NSApplication reads it.
// (Not in the test host, which shares the app's settings.)
if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { RestorationGuard.beginLaunch() }

// The custom NSDocumentController subclass must exist before any document
// opens, or NSDocumentController.shared silently falls back to the default
// class - so it's instantiated here, ahead of NSApplication.main().
_ = KorporaDocumentController()

let app = KorporaApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
