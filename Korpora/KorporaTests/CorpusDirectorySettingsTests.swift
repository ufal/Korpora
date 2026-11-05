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

    @MainActor @Test func theListOffersTheStandardFolderOnlyWhileAnotherIsChosen() throws {
        let box = try TestPando.Sandbox()
        _ = box
        let list = CorporaSettingsViewController()
        _ = list.view
        func resetButton() -> NSButton? {
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == "Use Standard Folder" { return button }
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
}
