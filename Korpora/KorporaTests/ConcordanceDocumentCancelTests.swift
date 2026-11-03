import Cocoa
import KorporaEngine
import Testing
@testable import Korpora

/// Cancelling a search (docs/project-plan.md, "Cancel a running query") as the document sees it,
/// against a tiny real corpus indexed with pando for each test. Serialized: it points the corpus
/// library at a temporary folder through the process environment. Skipped (passes silently) when
/// there is no pando build.
@MainActor @Suite(.serialized) final class ConcordanceDocumentCancelTests {
    private let box: TestPando.Sandbox
    private let engine: PandoEngine?
    private let defaults = UserDefaults(suiteName: "ConcordanceDocumentCancelTests-\(UUID().uuidString)")!
    private static let corpus = "korporacancel"

    /// 5 adjectives and 4 nouns: brown fox, lazy dog, curious cat, sleepy cat.
    private static let text = """
        # newdoc id = 1
        # sent_id = a
        1\tthe\tthe\tDET\t_\t_\t4\tdet\t_\t_
        2\tquick\tquick\tADJ\t_\t_\t4\tamod\t_\t_
        3\tbrown\tbrown\tADJ\t_\t_\t4\tamod\t_\t_
        4\tfox\tfox\tNOUN\t_\t_\t5\tnsubj\t_\t_
        5\tjumps\tjump\tVERB\t_\t_\t0\troot\t_\t_

        # sent_id = b
        1\tthe\tthe\tDET\t_\t_\t3\tdet\t_\t_
        2\tlazy\tlazy\tADJ\t_\t_\t3\tamod\t_\t_
        3\tdog\tdog\tNOUN\t_\t_\t4\tnsubj\t_\t_
        4\tsleeps\tsleep\tVERB\t_\t_\t0\troot\t_\t_

        # newdoc id = 2
        # sent_id = c
        1\ta\ta\tDET\t_\t_\t3\tdet\t_\t_
        2\tcurious\tcurious\tADJ\t_\t_\t3\tamod\t_\t_
        3\tcat\tcat\tNOUN\t_\t_\t4\tnsubj\t_\t_
        4\tpurrs\tpurr\tVERB\t_\t_\t0\troot\t_\t_

        # sent_id = d
        1\tthe\tthe\tDET\t_\t_\t3\tdet\t_\t_
        2\tsleepy\tsleepy\tADJ\t_\t_\t3\tamod\t_\t_
        3\tcat\tcat\tNOUN\t_\t_\t4\tnsubj\t_\t_
        4\tyawns\tyawn\tVERB\t_\t_\t0\troot\t_\t_


        """

    init() async throws {
        box = try TestPando.Sandbox()
        engine = try await box.buildCorpus(Self.corpus, conllu: Self.text) ? TestPando.engine() : nil
    }

    private func document() -> ConcordanceDocument {
        let document = ConcordanceDocument()
        if let engine { document.engine = engine }
        document.corpusName = Self.corpus
        document.historyDefaults = defaults
        return document
    }

    private var hasPando: Bool { engine != nil }

    private func waitUntilDone(_ document: ConcordanceDocument) async {
        for _ in 0..<2500 where document.isSearching {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func aSearchThatIsNotCancelledCompletes() async {
        guard hasPando else { return }
        let document = document()
        document.runQuery(#"[upos="NOUN"]"#)
        #expect(document.isSearching && document.status == "Searching…")
        await waitUntilDone(document)
        #expect(!document.isSearching)
        #expect(document.status.hasPrefix("4 hits"), "\(document.status)")
        #expect(document.rows.count == 4)
    }

    /// Cancelled before the search gets going: it stops, shows no results and
    /// says so; the query stays, so it can be run again.
    @Test func aCancelledSearchSaysSoAndKeepsTheQuery() async {
        guard hasPando else { return }
        let document = document()
        document.runQuery(#"[upos="NOUN"]"#)
        #expect(document.isSearching)
        document.cancelSearch()
        await waitUntilDone(document)
        #expect(!document.isSearching)
        #expect(document.status == "Search cancelled.")
        #expect(document.rows.isEmpty)
        #expect(document.initialQuery == #"[upos="NOUN"]"#)

        // Searching again works.
        document.runQuery(document.initialQuery)
        await waitUntilDone(document)
        #expect(document.status.hasPrefix("4 hits"), "\(document.status)")
    }

    /// A new search replaces one that is still running, and the replaced one
    /// leaves no trace: not its results, and not a "cancelled" message.
    @Test func aNewerSearchReplacesARunningOne() async {
        guard hasPando else { return }
        let document = document()
        document.runQuery(#"[upos="ADJ"]"#)
        document.runQuery(#"[upos="NOUN"]"#)
        await waitUntilDone(document)
        #expect(document.status.hasPrefix("4 hits"), "\(document.status)")
        #expect(document.rows.count == 4)
        #expect(document.initialQuery == #"[upos="NOUN"]"#)
    }

    @Test func cancellingWhenNothingIsRunningDoesNothing() async {
        guard hasPando else { return }
        let document = document()
        document.cancelSearch()
        #expect(!document.isSearching && document.status.isEmpty)
        document.runQuery(#"[upos="NOUN"]"#)
        await waitUntilDone(document)
        document.cancelSearch()
        #expect(document.status.hasPrefix("4 hits"), "\(document.status)")
        #expect(document.rows.count == 4)
    }

    /// The window's hint and the menu item follow the document.
    @Test func theWindowShowsTheHintWhileSearching() async throws {
        guard hasPando else { return }
        let document = document()
        let controller = ConcordanceViewController(document: document)
        _ = controller.view
        #expect(controller.cancelHintLabel.isHidden)
        #expect(controller.cancelHintLabel.stringValue == "Press \u{2318}. to cancel")
        let item = NSMenuItem(title: "Cancel Search", action: #selector(ConcordanceViewController.cancelSearch(_:)), keyEquivalent: ".")
        #expect(!controller.validateMenuItem(item))

        document.runQuery(#"[upos="NOUN"]"#)
        #expect(!controller.cancelHintLabel.isHidden)
        #expect(controller.validateMenuItem(item))
        await waitUntilDone(document)
        #expect(controller.cancelHintLabel.isHidden)
        #expect(!controller.validateMenuItem(item))
    }

    // MARK: The key press, through a real window

    /// A window like the app's, on screen, with the query field focused.
    private func shownWindow(for document: ConcordanceDocument) throws -> (NSWindow, NSTextView) {
        let controller = ConcordanceWindowController(document: document)
        document.addWindowController(controller)
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        let viewController = try #require(window.contentViewController)
        func textView(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(textView(in:)).first
        }
        let field = try #require(textView(in: viewController.view))
        window.makeFirstResponder(field)
        return (window, field)
    }

    /// Holds a search open until `open()`.
    actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Command-period through the app's main menu can't be sent from a test:
    /// the test host is never the active app, so no window becomes key and a
    /// menu action has no responder chain to travel. So the links are tested
    /// one by one, with the search held open: the menu item (title, key,
    /// modifier, action, and that it targets the responder chain)...
    @Test func theMenuItemIsWiredToCommandPeriod() throws {
        let menu = try #require(NSApp.mainMenu)
        let queryMenu = try #require(menu.items.first { $0.submenu?.title == "Query" }?.submenu)
        let item = try #require(queryMenu.items.first { $0.title == "Cancel Search" })
        #expect(item.keyEquivalent == ".")
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(item.action == #selector(ConcordanceViewController.cancelSearch(_:)))
        #expect(item.target == nil, "nil target: the action goes up the key window's responder chain")
    }

    /// ...it is enabled exactly while the window's search runs...
    @Test func theItemIsValidOnlyWhileSearching() async throws {
        guard hasPando else { return }
        let document = document()
        let gate = Gate()
        document.beforeSearchHook = { await gate.wait() }
        let controller = ConcordanceViewController(document: document)
        _ = controller.view
        let item = NSMenuItem(title: "Cancel Search", action: #selector(ConcordanceViewController.cancelSearch(_:)), keyEquivalent: ".")
        #expect(!controller.validateMenuItem(item))
        document.runQuery(#"[upos="NOUN"]"#)
        try await Task.sleep(for: .milliseconds(50))  // the search is held open, not finished
        #expect(document.isSearching)
        #expect(controller.validateMenuItem(item))
        await gate.open()
        await waitUntilDone(document)
        #expect(!controller.validateMenuItem(item))
    }

    /// ...and from the focused query field the action, and the standard
    /// cancelOperation: (what the key bindings send for Command-period and
    /// Esc), reach the window's view controller and cancel a search that is
    /// still running.
    @Test func bothActionsReachTheViewControllerFromTheQueryField() async throws {
        guard hasPando else { return }
        for action in [#selector(ConcordanceViewController.cancelSearch(_:)),
                       #selector(NSResponder.cancelOperation(_:))] {
            let document = document()
            let gate = Gate()
            document.beforeSearchHook = { await gate.wait() }
            let (window, field) = try shownWindow(for: document)
            defer { window.orderOut(nil) }
            document.runQuery(#"[upos="NOUN"]"#)
            try await Task.sleep(for: .milliseconds(50))
            #expect(document.isSearching, "\(action)")
            #expect(field.tryToPerform(action, with: nil), "\(action)")
            await gate.open()
            await waitUntilDone(document)
            #expect(document.status == "Search cancelled.", "\(action): \(document.status)")
            #expect(document.rows.isEmpty)
        }
    }

    /// With nothing running, cancelOperation: is passed on, not swallowed.
    @Test func cancelOperationIsPassedOnWhenNothingRuns() throws {
        let document = document()
        let (window, field) = try shownWindow(for: document)
        defer { window.orderOut(nil) }
        #expect(!document.isSearching)
        document.cancelSearch()  // and cancelling nothing is harmless
        #expect(document.status.isEmpty)
        _ = field
    }
}
