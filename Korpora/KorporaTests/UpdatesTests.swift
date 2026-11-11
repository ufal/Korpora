import AppKit
import Foundation
import Testing
@testable import Korpora

@MainActor @Suite struct UpdatesTests {
    @Test func theAppKnowsWhereTheFeedIsAndWhichKeySignsIt() throws {
        let info = Bundle(for: AppDelegate.self).infoDictionary ?? [:]
        let feed = try #require(info["SUFeedURL"] as? String)
        #expect(feed == "https://github.com/ufal/Korpora/releases/latest/download/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String)
        // An EdDSA public key: 32 bytes in base64.
        #expect(Data(base64Encoded: key)?.count == 32)
    }

    @Test func theAppMenuHasCheckForUpdatesAfterAbout() throws {
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let menu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let titles = menu.items.map(\.title)
        let about = try #require(titles.firstIndex(of: "About Korpora"))
        #expect(titles[about + 1] == "Check for Updates\u{2026}")
        #expect(menu.items[about + 1].action == #selector(AppDelegate.checkForUpdates(_:)))
    }

    @Test func anUpdateClosesTheSheetsThatWouldBlockTheQuit() {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let inner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        for window in [parent, sheet, inner] { window.isReleasedWhenClosed = false }
        parent.makeKeyAndOrderFront(nil)
        parent.beginSheet(sheet, completionHandler: nil)
        sheet.beginSheet(inner, completionHandler: nil)
        #expect(parent.attachedSheet === sheet)
        #expect(AppDelegate.endAllSheets())
        #expect(parent.attachedSheet == nil && sheet.attachedSheet == nil)
        #expect(!AppDelegate.endAllSheets(), "nothing left to close")
        parent.close()
    }
}
