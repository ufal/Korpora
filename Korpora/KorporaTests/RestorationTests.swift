import AppKit
import Foundation
import Testing
@testable import Korpora

@MainActor @Suite(.serialized) struct RestorationTests {
    /// Quitting keeps a concordance (its draft is written, which the system reopens); closing its window discards it
    /// (the draft is deleted) and neither asks anything.
    @Test func aDraftIsWrittenOnRequestAndClosingDeletesIt() async throws {
        let doc = ConcordanceDocument()
        doc.corpusName = "draft-test"
        doc.initialQuery = #"[lemma="a"]"#
        NSDocumentController.shared.addDocument(doc)
        #expect(!doc.isDocumentEdited, "no save prompt, ever, outside the moment a draft is written")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in doc.writeDraft { c.resume() } }
        let url = try #require(doc.autosavedContentsFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("draft-test") && text.contains("lemma"))
        #expect(!doc.isDocumentEdited)
        doc.close()
        #expect(!FileManager.default.fileExists(atPath: url.path), "a closed concordance is not resumed")
    }

    @Test func aDocumentWithNoQueryYetWritesNoDraft() async {
        let doc = ConcordanceDocument()
        NSDocumentController.shared.addDocument(doc)
        var done = false
        doc.writeDraft { done = true }
        #expect(done)
        #expect(doc.autosavedContentsFileURL == nil)
        doc.close()
    }

    private func sandbox() -> (UserDefaults, URL, () -> Void) {
        let name = "korpora.test.guard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString).savedState", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "x".write(to: folder.appendingPathComponent("windows.plist"), atomically: true, encoding: .utf8)
        return (defaults, folder, { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) })
    }

    @Test func aLaunchThatFinishedLeavesTheSavedWindowsAlone() {
        let (defaults, folder, cleanup) = sandbox()
        defer { cleanup() }
        #expect(!RestorationGuard.beginLaunch(defaults: defaults, savedState: folder))
        RestorationGuard.finishLaunch(defaults: defaults)
        #expect(!RestorationGuard.beginLaunch(defaults: defaults, savedState: folder), "the previous launch finished")
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aLaunchThatNeverFinishedDropsTheSavedWindowsOfTheNextOne() {
        let (defaults, folder, cleanup) = sandbox()
        defer { cleanup() }
        #expect(!RestorationGuard.beginLaunch(defaults: defaults, savedState: folder))
        // No finishLaunch: it hung or crashed. The next launch starts clean.
        #expect(RestorationGuard.beginLaunch(defaults: defaults, savedState: folder))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        // And that launch is itself guarded.
        RestorationGuard.finishLaunch(defaults: defaults)
        #expect(!RestorationGuard.beginLaunch(defaults: defaults, savedState: folder))
    }

    @Test func theSavedStateFolderIsTheSystemsOwn() throws {
        let url = try #require(RestorationGuard.savedStateFolder(bundleIdentifier: "cz.cuni.mff.ufal.korpora"))
        #expect(url.path.hasSuffix("Library/Saved Application State/cz.cuni.mff.ufal.korpora.savedState"))
    }

    /// AppKit closes every untitled document that says it has no edits before it asks the app delegate anything, so
    /// a concordance has to say it is edited from the moment a quit starts (and only then).
    @Test func aConcordanceSaysItIsEditedOnlyWhileAQuitGoesOn() {
        let doc = ConcordanceDocument()
        #expect(!doc.isDocumentEdited)
        ConcordanceDocument.isQuitting = true
        #expect(doc.isDocumentEdited)
        (NSApp as? KorporaApplication)?.quitWasCancelled()
        #expect(!doc.isDocumentEdited)
    }

    @Test func theApplicationObjectIsOursSoAQuitGoesThroughIt() {
        #expect(NSApp is KorporaApplication)
    }

    /// The first sheet of a launch waits for the system to put the windows back; one asked for later does not.
    @Test func theFirstSheetOfALaunchWaitsForTheRestorationAndALaterOneDoesNot() async {
        LaunchRestoration.begin(timeout: 0.2)
        var told: [Bool] = []
        LaunchRestoration.afterRestoration { told.append($0) }
        #expect(told.isEmpty, "still restoring")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(told == [true], "it waited, so it is part of the launch")
        LaunchRestoration.afterRestoration { told.append($0) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(told == [true, false], "asked for after the launch: not held back")
    }
}
