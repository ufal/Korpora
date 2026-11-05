import Cocoa
import Testing
@testable import Korpora
@testable import KorporaEngine

/// The setting for where Korpora keeps the corpora it builds. These never touch the app's real preferences
/// (the tests run inside the app): they use their own defaults, or the library's static override directly.
@Suite(.serialized) struct CorpusDirectorySettingsTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CorpusDirectorySettingsTests-\(UUID().uuidString)")!
    }

    @Test func theChosenFolderIsStoredAndCleared() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.corporaDirectory == nil, "standard folder unless chosen")
        settings.corporaDirectory = URL(fileURLWithPath: "/Volumes/Big SSD/Corpora")
        #expect(settings.corporaDirectory?.path == "/Volumes/Big SSD/Corpora")
        settings.corporaDirectory = nil
        #expect(settings.corporaDirectory == nil)
    }

    @Test func settingsWithTheirOwnDefaultsLeaveTheLibraryAlone() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.corporaDirectory = URL(fileURLWithPath: "/Volumes/Big SSD/Corpora")
        #expect(CorpusLibrary.customBaseDirectory == nil, "only the app's own settings steer the library")
    }

    @MainActor @Test func theListOffersResetToDefaultOnlyWhileAnotherFolderIsChosen() throws {
        let box = try TestPando.Sandbox()
        _ = box
        let list = CorporaSettingsViewController()
        _ = list.view
        func resetButton() -> NSButton? {
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == "Reset to Default" { return button }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(list.view)
        }
        let button = try #require(resetButton())
        #expect(button.isHidden, "nothing to go back from")

        CorpusLibrary.customBaseDirectory = URL(fileURLWithPath: "/Volumes/Big SSD/Corpora")
        defer { CorpusLibrary.customBaseDirectory = nil }
        list.reloadCorpora()
        #expect(!button.isHidden)
    }

    @Test func theTimeRemainingIsGuessedFromTheSpeedSoFarAndOnlyAfterAFewSeconds() {
        typealias Sheet = TransferProgressSheetController
        #expect(Sheet.remaining(done: 0, total: 100, elapsed: 10) == nil, "nothing done yet")
        #expect(Sheet.remaining(done: 10, total: 100, elapsed: 1) == nil, "too early to tell")
        #expect(Sheet.remaining(done: 25, total: 100, elapsed: 10) == 30, "a quarter in 10 s leaves 30 s")
        #expect(Sheet.describe(remaining: 4) == "almost done")
        #expect(Sheet.describe(remaining: 30) == "less than a minute remaining")
        #expect(Sheet.describe(remaining: 60) == "about a minute remaining")
        #expect(Sheet.describe(remaining: 240) == "about 4 minutes remaining")
        #expect(Sheet.describe(remaining: 7200) == "about 2 hours remaining")
        #expect(Sheet.detail(done: 1_000_000, total: 4_000_000, elapsed: 1).hasSuffix("estimating the time remaining\u{2026}"))
        #expect(Sheet.detail(done: 1_000_000, total: 4_000_000, elapsed: 10).hasSuffix("about 30 seconds remaining") == false)
        #expect(Sheet.detail(done: 1_000_000, total: 4_000_000, elapsed: 10).hasSuffix("less than a minute remaining"))
    }

    @MainActor @Test func theSheetShowsHowFarTheCopyHasComeAndCanBeCancelled() {
        let sheet = TransferProgressSheetController(headline: "Copying \u{201C}x\u{201D} into Korpora")
        _ = sheet.view
        var cancelled = false
        sheet.onCancel = { cancelled = true }
        sheet.update(.init(bytesDone: 25, bytesTotal: 100, name: "x"))
        func labels(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels)
        }
        func bars(_ view: NSView) -> [NSProgressIndicator] {
            (view as? NSProgressIndicator).map { [$0] } ?? view.subviews.flatMap(bars)
        }
        #expect(bars(sheet.view).first?.doubleValue == 0.25)
        #expect(labels(sheet.view).contains { $0.stringValue == "\u{201C}x\u{201D}" })
        func cancel(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Cancel" { return button }
            return view.subviews.lazy.compactMap(cancel).first
        }
        cancel(sheet.view)?.performClick(nil)
        #expect(cancelled)
        #expect(cancel(sheet.view)?.isEnabled == false, "pressed once")
        #expect(labels(sheet.view).contains { $0.stringValue == "Stopping\u{2026}" })
    }
}
