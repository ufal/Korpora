import AppKit
import Foundation
import Testing
@testable import Korpora

@MainActor @Suite(.serialized) struct RestorationTests {
    /// The standard model: a concordance with a query counts as edited, so AppKit autosaves it as a draft (which the
    /// next launch reopens); closing it discards it, draft included, and never asks.
    @Test func aConcordanceWithAQueryIsAutosavedAndClosingDiscardsItWithoutAsking() async throws {
        let doc = ConcordanceDocument()
        doc.corpusName = "draft-test"
        doc.initialQuery = #"[lemma="a"]"#
        NSDocumentController.shared.addDocument(doc)
        #expect(!doc.isDocumentEdited, "nothing has changed yet")
        doc.markChanged()
        #expect(doc.isDocumentEdited)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            doc.autosave(withImplicitCancellability: false) { _ in c.resume() }
        }
        let url = try #require(doc.autosavedContentsFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("draft-test") && text.contains("lemma"))
        // Closing the window asks the document whether it may close: yes, at once, with no sheet.
        let asked = CloseAsker()
        doc.canClose(withDelegate: asked, shouldClose: #selector(CloseAsker.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        #expect(asked.answers == [true])
        doc.close()
        #expect(!FileManager.default.fileExists(atPath: url.path), "a closed concordance is not resumed")
    }

    @Test func aDocumentWithNoQueryYetIsNotMarkedChanged() {
        let doc = ConcordanceDocument()
        doc.markChanged()
        #expect(!doc.isDocumentEdited, "the New Concordance sheet was never answered: nothing to keep")
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

    @Test func theApplicationObjectIsOursSoAQuitGoesThroughIt() {
        #expect(NSApp is KorporaApplication)
    }

    /// A concordance the app opens by itself in the first seconds of a launch waits for the restored ones; one the
    /// user asks for, or any later one, does not.
    @Test func aConcordanceOpenedByTheLaunchWaitsAndOneAskedForDoesNot() async {
        LaunchRestoration.grace = 0.2
        LaunchRestoration.launchWindow = 5
        defer { LaunchRestoration.grace = 1; LaunchRestoration.launchWindow = 4 }
        LaunchRestoration.begin()
        var told: [Bool] = []
        LaunchRestoration.afterRestoration { told.append($0) }
        #expect(told.isEmpty, "waiting for the restored concordances")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(told == [true], "it waited, so it is the launch's own")
        LaunchRestoration.userRequestedNew = true
        LaunchRestoration.afterRestoration { told.append($0) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(told == [true, false], "asked for by the user: not held back, not closed")
        LaunchRestoration.launchWindow = 0
        LaunchRestoration.afterRestoration { told.append($0) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(told == [true, false, false], "after the launch window: not the launch's own")
    }
}

/// Stands in for the window that asks a document whether it may close.
final class CloseAsker: NSObject {
    var answers: [Bool] = []
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        answers.append(shouldClose)
    }
}
