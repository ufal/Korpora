import Cocoa
import KorporaEngine

/// The sheet a brand-new `ConcordanceDocument` presents immediately on creation, since it has
/// nothing to show until a corpus and a query are known.
///
/// The corpus picker lists the corpora in the library - opening one, never creating one ("New
/// Concordance" means a new query/result document); with none yet it says so and offers to import
/// one. A subcorpus, though, genuinely can be created here (see `NewSubcorpusPopoverController`).
final class NewConcordanceSheetController: NSViewController {
    private enum SubcorpusItem {
        static let whole = "Whole Corpus"
        static let newOne = "New Subcorpus…"
    }

    var corpusName: String = ""
    var query: String = ""
    /// (corpus name, subcorpus or nil for the whole corpus, query)
    var onCommit: ((String, Subcorpus?, String) -> Void)?
    var onCancel: (() -> Void)?

    private let corpusPopUp = NSPopUpButton()
    private let infoLabel = NSTextField(wrappingLabelWithString: "")
    private let subcorpusPopUp = NSPopUpButton()
    private let queryField = CQLQueryField()
    private let exampleLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Open Corpora Settings\u{2026}", target: nil, action: nil)
    private var corporaObserver: NSObjectProtocol?
    private var searchButton: NSButton!
    private var currentCorpusInfo: CorpusInfo?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

        let title = NSTextField(labelWithString: "New Concordance")
        title.font = .boldSystemFont(ofSize: 13)

        let corpusLabel = NSTextField(labelWithString: "Corpus:")
        let availableCorpora = CorpusLibrary.names()
        fillCorpusPopUp(availableCorpora, keeping: corpusName)
        corpusPopUp.target = self
        corpusPopUp.action = #selector(corpusSelectionChanged)

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor

        let subcorpusLabel = NSTextField(labelWithString: "Subcorpus:")
        subcorpusPopUp.target = self
        subcorpusPopUp.action = #selector(subcorpusSelectionChanged)

        let queryLabel = NSTextField(labelWithString: "Query:")
        exampleLabel.stringValue = "For example  [lemma=\"house\"]   or   [upos=\"ADJ\"] [lemma=\"house\"]"
        exampleLabel.font = .systemFont(ofSize: 11)
        exampleLabel.textColor = .secondaryLabelColor
        importButton.target = self
        importButton.action = #selector(importTapped)
        importButton.controlSize = .small
        importButton.isHidden = !availableCorpora.isEmpty
        importButton.toolTip = "Add or import a corpus in Settings; it appears here when it is ready."
        // A corpus added or imported in Settings while this sheet is open shows up in the list.
        corporaObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.corporaDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.corporaChanged() }
        queryField.text = query
        queryField.onSubmit = { [weak self] in self?.searchTapped() }

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"

        searchButton = NSButton(title: "Search", target: self, action: #selector(searchTapped))
        searchButton.keyEquivalent = "\r"
        searchButton.bezelStyle = .rounded
        searchButton.isEnabled = !availableCorpora.isEmpty

        let views: [NSView] = [
            title, corpusLabel, corpusPopUp, infoLabel, subcorpusLabel, subcorpusPopUp,
            queryLabel, queryField, exampleLabel, importButton, cancelButton, searchButton,
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            corpusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            corpusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            corpusPopUp.centerYAnchor.constraint(equalTo: corpusLabel.centerYAnchor),
            corpusPopUp.leadingAnchor.constraint(equalTo: corpusLabel.trailingAnchor, constant: 8),

            infoLabel.topAnchor.constraint(equalTo: corpusLabel.bottomAnchor, constant: 6),
            infoLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            subcorpusLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 12),
            subcorpusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            subcorpusPopUp.centerYAnchor.constraint(equalTo: subcorpusLabel.centerYAnchor),
            subcorpusPopUp.leadingAnchor.constraint(equalTo: subcorpusLabel.trailingAnchor, constant: 8),

            queryLabel.topAnchor.constraint(equalTo: subcorpusLabel.bottomAnchor, constant: 16),
            queryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            queryField.topAnchor.constraint(equalTo: queryLabel.bottomAnchor, constant: 6),
            queryField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            queryField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            exampleLabel.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 6),
            exampleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            exampleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            importButton.centerYAnchor.constraint(equalTo: corpusPopUp.centerYAnchor),
            importButton.leadingAnchor.constraint(equalTo: corpusPopUp.trailingAnchor, constant: 12),

            searchButton.topAnchor.constraint(greaterThanOrEqualTo: exampleLabel.bottomAnchor, constant: 16),
            searchButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            cancelButton.centerYAnchor.constraint(equalTo: searchButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -8),
        ])

        // Explicit, not relying on AppKit's auto-generated Tab loop:
        // `queryField` is a custom composite view (NSScrollView + a nested
        // NSTextView, not a standard control), which that heuristic loop
        // doesn't reliably reach into - without this, Tabbing from
        // `subcorpusPopUp` skipped straight past the query field to the
        // buttons (found via manual testing, 2026-09-07).
        corpusPopUp.nextKeyView = subcorpusPopUp
        subcorpusPopUp.nextKeyView = queryField.textView
        queryField.textView.nextKeyView = searchButton
        searchButton.nextKeyView = cancelButton

        view = root
        preferredContentSize = NSSize(width: 480, height: 300)

        refreshForSelectedCorpus()
    }

    deinit {
        if let corporaObserver { NotificationCenter.default.removeObserver(corporaObserver) }
    }

    private func fillCorpusPopUp(_ names: [String], keeping selected: String) {
        corpusPopUp.removeAllItems()
        if names.isEmpty {
            corpusPopUp.addItem(withTitle: "No corpora yet")
            corpusPopUp.isEnabled = false
        } else {
            corpusPopUp.addItems(withTitles: names)
            corpusPopUp.isEnabled = true
            if !selected.isEmpty { corpusPopUp.selectItem(withTitle: selected) }
        }
    }

    /// The library changed (Settings): rebuild the list, keep the choice if it is still there.
    private func corporaChanged() {
        let names = CorpusLibrary.names()
        let before = corpusPopUp.isEnabled ? corpusPopUp.titleOfSelectedItem : nil
        fillCorpusPopUp(names, keeping: before ?? "")
        searchButton?.isEnabled = !names.isEmpty
        importButton.isHidden = !names.isEmpty
        refreshForSelectedCorpus()
    }

    /// Nothing focuses `queryField` just because the sheet is on screen -
    /// same root cause as the Tab-loop gap above, a custom composite view
    /// isn't what AppKit's initial-first-responder heuristics expect
    /// either. `viewDidAppear` (not `loadView`) is the first point the view
    /// is guaranteed to actually have a window to focus within.
    override func viewDidAppear() {
        super.viewDidAppear()
        queryField.focus()
    }

    private func refreshForSelectedCorpus() {
        guard let name = corpusPopUp.titleOfSelectedItem, corpusPopUp.isEnabled else {
            infoLabel.stringValue = "Korpora has no corpora yet. Import annotated text or add an index folder in Settings."
            subcorpusPopUp.removeAllItems()
            currentCorpusInfo = nil
            queryField.completionProvider = nil
            return
        }
        reloadSubcorpusList(for: name)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let corpus = try await Engines.default.openCorpus(name: name)
                let info = try await corpus.info()
                currentCorpusInfo = info
                // Rebuilt per selected corpus, from the info() we just
                // fetched rather than making the provider repeat that call
                // (6.8).
                queryField.completionProvider = CQLCompletionProvider(corpusInfo: info)
                var parts: [String] = ["\(info.sizeTokens.formatted()) tokens"]
                if !info.attributes.isEmpty {
                    parts.append("Token attributes: " + info.attributes.joined(separator: ", "))
                }
                let described = info.structures.filter { !$0.attributes.isEmpty }
                if !described.isEmpty {
                    let structs = described.map { s in
                        "\(s.name) (\(s.attributes.prefix(8).joined(separator: ", "))\(s.attributes.count > 8 ? ", \u{2026}" : ""))"
                    }
                    parts.append("Text properties: " + structs.joined(separator: ", "))
                }
                infoLabel.stringValue = parts.joined(separator: "\n")
            } catch {
                currentCorpusInfo = nil
                queryField.completionProvider = nil
                infoLabel.stringValue = "\(error)"
            }
        }
    }

    private func reloadSubcorpusList(for corpusName: String) {
        subcorpusPopUp.removeAllItems()
        subcorpusPopUp.addItem(withTitle: SubcorpusItem.whole)
        let existing = SubcorpusLibrary.subcorpora(of: corpusName).map(\.name)
        if !existing.isEmpty {
            subcorpusPopUp.menu?.addItem(.separator())
            subcorpusPopUp.addItems(withTitles: existing)
        }
        subcorpusPopUp.menu?.addItem(.separator())
        subcorpusPopUp.addItem(withTitle: SubcorpusItem.newOne)
    }

    @objc private func corpusSelectionChanged() {
        refreshForSelectedCorpus()
    }

    @objc private func subcorpusSelectionChanged() {
        guard subcorpusPopUp.titleOfSelectedItem == SubcorpusItem.newOne,
              let corpusName = corpusPopUp.titleOfSelectedItem else { return }
        // Reset immediately - becomes the new subcorpus's name on success,
        // rather than staying stuck on "New Subcorpus…" if the popover is
        // dismissed without creating one.
        subcorpusPopUp.selectItem(withTitle: SubcorpusItem.whole)

        let popover = NSPopover()
        let controller = NewSubcorpusPopoverController()
        controller.corpusInfo = currentCorpusInfo
        controller.corpusName = corpusName
        controller.onCreate = { [weak self, weak popover] subcorpus in
            guard let self else { return }
            do {
                try SubcorpusLibrary.save(subcorpus, in: corpusName)
                reloadSubcorpusList(for: corpusName)
                subcorpusPopUp.selectItem(withTitle: subcorpus.name)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn\u{2019}t Save the Subcorpus"
                alert.informativeText = "\(error)"
                alert.runModal()
            }
            popover?.close()
        }
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: subcorpusPopUp.bounds, of: subcorpusPopUp, preferredEdge: .maxY)
    }

    @objc private func searchTapped() {
        guard let corpus = corpusPopUp.titleOfSelectedItem, corpusPopUp.isEnabled else { return }
        var subcorpus: Subcorpus?
        if let selected = subcorpusPopUp.titleOfSelectedItem,
           selected != SubcorpusItem.whole, selected != SubcorpusItem.newOne {
            subcorpus = SubcorpusLibrary.subcorpora(of: corpus).first { $0.name == selected }
        }
        onCommit?(corpus, subcorpus, queryField.text)
        dismiss(self)
    }

    /// With no corpus yet, the way to get one is Settings > Corpora. The sheet stays: the Settings window opens
    /// beside it, and the list here fills in when a corpus is added.
    @objc private func importTapped() {
        SettingsWindowController.shared.show(.corpora)
    }

    @objc private func cancelTapped() {
        onCancel?()
        dismiss(self)
    }
}
