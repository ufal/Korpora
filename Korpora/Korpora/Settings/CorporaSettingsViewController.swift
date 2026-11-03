import Cocoa
import KorporaEngine

/// A small horizontal gauge - total vs. currently-available memory - no
/// charting library needed for something this simple.
private final class MemoryBarView: NSView {
    private let usedView = NSView()
    private var usedWidthConstraint: NSLayoutConstraint!
    private var lastFraction: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = 4

        usedView.wantsLayer = true
        usedView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        usedView.layer?.cornerRadius = 4
        usedView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(usedView)
        usedWidthConstraint = usedView.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            usedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            usedView.topAnchor.constraint(equalTo: topAnchor),
            usedView.bottomAnchor.constraint(equalTo: bottomAnchor),
            usedWidthConstraint,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setUsedFraction(_ fraction: Double) {
        lastFraction = max(0, min(1, fraction))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        usedWidthConstraint.constant = bounds.width * CGFloat(lastFraction)
    }
}

/// Every corpus the app can open, in one list (docs/pando-gui-plan.md): the ones Korpora built
/// from annotated text (CoNLL-U) and index folders linked from elsewhere. They are listed, removed
/// and kept in memory (see `CorpusMemoryResidency`) the same way.
final class CorporaSettingsViewController: NSViewController {
    private struct Row {
        let entry: CorpusLibrary.Entry
        let sizeBytes: UInt64
        var keepResident: Bool

        var name: String { entry.name }
    }

    private enum Column: String { case name, tokens, source, size, resident }

    private let directoryPathLabel = NSTextField(labelWithString: "")
    private let engineNoticeLabel = NSTextField(wrappingLabelWithString: "")
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let memoryBar = MemoryBarView()
    private let memoryLabel = NSTextField(labelWithString: "")
    private let minimumFreeField = NSTextField(string: "")
    private let removeButton = NSButton(
        image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
        target: nil, action: nil)

    private var rows: [Row] = []
    private var refreshTimer: Timer?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 440))
        // Follow the window when it's resized; without this Auto Layout pins the
        // view to the size it was created with.
        root.autoresizingMask = [.width, .height]

        let directoryLabel = NSTextField(labelWithString: "Corpora built by Korpora are stored in:")
        directoryPathLabel.lineBreakMode = .byTruncatingMiddle
        directoryPathLabel.font = .systemFont(ofSize: 11)
        directoryPathLabel.textColor = .secondaryLabelColor
        let chooseDirectoryButton = NSButton(title: "Show in Finder", target: self, action: #selector(showLibraryInFinder))
        engineNoticeLabel.font = .systemFont(ofSize: 11)
        engineNoticeLabel.textColor = .systemRed
        engineNoticeLabel.isHidden = true

        tableView.headerView = NSTableHeaderView()
        // Name takes whatever room there is; the others are wide enough for
        // their headings and don't shrink below that ("Keep in Memory" was
        // cut to "Keep in Me…").
        let nameColumn = NSTableColumn(identifier: .init(Column.name.rawValue))
        nameColumn.title = "Name"
        nameColumn.minWidth = 100
        nameColumn.width = 150
        nameColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        let tokensColumn = NSTableColumn(identifier: .init(Column.tokens.rawValue))
        tokensColumn.title = "Tokens"
        tokensColumn.minWidth = 90
        tokensColumn.width = 100
        tokensColumn.resizingMask = .userResizingMask
        let sourceColumn = NSTableColumn(identifier: .init(Column.source.rawValue))
        sourceColumn.title = "Source"
        sourceColumn.minWidth = 90
        sourceColumn.width = 100
        sourceColumn.resizingMask = .userResizingMask
        let sizeColumn = NSTableColumn(identifier: .init(Column.size.rawValue))
        sizeColumn.title = "On disk"
        sizeColumn.minWidth = 70
        sizeColumn.width = 80
        sizeColumn.resizingMask = .userResizingMask
        let residentColumn = NSTableColumn(identifier: .init(Column.resident.rawValue))
        residentColumn.title = "Keep in Memory"
        residentColumn.minWidth = 125
        residentColumn.width = 130
        residentColumn.resizingMask = .userResizingMask
        for column in [nameColumn, tokensColumn, sourceColumn, sizeColumn, residentColumn] {
            tableView.addTableColumn(column)
        }
        // Extra width goes to the Name column, not spread over all four.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let importButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
            target: self, action: #selector(showAddMenu(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeSelectedCorpus)
        removeButton.isEnabled = false
        let addHint = NSTextField(labelWithString:
            "+ imports annotated text (CoNLL-U), or adds an index folder built elsewhere.")
        addHint.font = .systemFont(ofSize: 11)
        addHint.textColor = .secondaryLabelColor

        let memoryTitle = NSTextField(labelWithString: "Memory:")
        memoryLabel.font = .systemFont(ofSize: 11)
        memoryLabel.textColor = .secondaryLabelColor
        let minimumFreeLabel = NSTextField(labelWithString: "Minimum free after keeping a corpus resident:")
        let minimumFreeSuffix = NSTextField(labelWithString: "GB")
        minimumFreeField.target = self
        minimumFreeField.action = #selector(minimumFreeChanged)

        let views: [NSView] = [
            directoryLabel, directoryPathLabel, chooseDirectoryButton, engineNoticeLabel,
            scrollView, importButton, removeButton, addHint,
            memoryTitle, memoryBar, memoryLabel,
            minimumFreeLabel, minimumFreeField, minimumFreeSuffix,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        importButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        minimumFreeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        memoryBar.heightAnchor.constraint(equalToConstant: 12).isActive = true

        NSLayoutConstraint.activate([
            directoryLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            directoryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            chooseDirectoryButton.centerYAnchor.constraint(equalTo: directoryLabel.centerYAnchor),
            chooseDirectoryButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            directoryPathLabel.topAnchor.constraint(equalTo: directoryLabel.bottomAnchor, constant: 4),
            directoryPathLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            directoryPathLabel.trailingAnchor.constraint(equalTo: chooseDirectoryButton.leadingAnchor, constant: -8),

            engineNoticeLabel.topAnchor.constraint(equalTo: directoryPathLabel.bottomAnchor, constant: 8),
            engineNoticeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            engineNoticeLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: engineNoticeLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            // At least 140 tall, and the pane's spare height when the window is
            // resized: the list is the one thing that benefits from more room.
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            importButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            importButton.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            removeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            removeButton.leadingAnchor.constraint(equalTo: importButton.trailingAnchor, constant: 2),

            addHint.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            addHint.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 10),
            addHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            memoryTitle.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 20),
            memoryTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            memoryBar.centerYAnchor.constraint(equalTo: memoryTitle.centerYAnchor),
            memoryBar.leadingAnchor.constraint(equalTo: memoryTitle.trailingAnchor, constant: 8),
            memoryBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            memoryLabel.topAnchor.constraint(equalTo: memoryBar.bottomAnchor, constant: 4),
            memoryLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            memoryLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            minimumFreeLabel.topAnchor.constraint(equalTo: memoryLabel.bottomAnchor, constant: 16),
            minimumFreeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            minimumFreeField.centerYAnchor.constraint(equalTo: minimumFreeLabel.centerYAnchor),
            minimumFreeField.leadingAnchor.constraint(equalTo: minimumFreeLabel.trailingAnchor, constant: 8),
            minimumFreeSuffix.centerYAnchor.constraint(equalTo: minimumFreeLabel.centerYAnchor),
            minimumFreeSuffix.leadingAnchor.constraint(equalTo: minimumFreeField.trailingAnchor, constant: 4),
            minimumFreeSuffix.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 600, height: 440)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        directoryPathLabel.stringValue = CorpusLibrary.baseDirectory.path
        if let reason = Engines.unavailableReason {
            engineNoticeLabel.stringValue = "The search engine couldn\u{2019}t be loaded, so corpora can\u{2019}t be opened or built: \(reason)"
            engineNoticeLabel.isHidden = false
        }
        minimumFreeField.stringValue = String(AppSettings.shared.minimumFreeMemoryAfterResidency / 1_000_000_000)
        reloadCorpora()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateMemoryBar()
            self?.refreshMemoryDependentColumn()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Rebuilds the list. The selection follows the corpus, not the row
    /// number, so adding or removing another corpus doesn't move it.
    func reloadCorpora() {
        let selectedName = selectedCorpusName
        rows = AppSettings.shared.corpusLibraryEntries()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { entry in
                Row(entry: entry,
                    sizeBytes: CorpusMemoryResidency.directorySize(entry.directory.resolvingSymlinksInPath()),
                    keepResident: AppSettings.shared.isKeepResident(entry.name))
            }
        tableView.reloadData()
        if let selectedName, let row = rows.firstIndex(where: { $0.name == selectedName }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateRemoveButton()
        updateMemoryBar()
    }

    var selectedCorpusName: String? {
        rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow].name : nil
    }

    /// Whether a corpus still fits in free memory changes as memory does, so
    /// the "Keep in Memory" checkboxes are refreshed on a timer. Only that
    /// column: `reloadData()` would clear the selection, and with it the
    /// chance to click "\u{2212}" (found in the macOS 15 smoke test of 0.2).
    func refreshMemoryDependentColumn() {
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.resident.rawValue))
        guard column >= 0, !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count),
                             columnIndexes: IndexSet(integer: column))
    }

    private func updateMemoryBar() {
        let total = CorpusMemoryResidency.totalMemory
        let available = CorpusMemoryResidency.availableMemory()
        guard total > 0 else { return }
        memoryBar.setUsedFraction(1 - Double(available) / Double(total))
        let formatter = ByteCountFormatter()
        memoryLabel.stringValue =
            "\(formatter.string(fromByteCount: Int64(available))) available of \(formatter.string(fromByteCount: Int64(total)))"
    }

    @objc private func showLibraryInFinder() {
        try? FileManager.default.createDirectory(at: CorpusLibrary.baseDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(CorpusLibrary.baseDirectory)
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("Import Annotated Text (CoNLL-U)\u{2026}", #selector(importCorpusTapped)),
                                ("Add Index Folder\u{2026}", #selector(addExistingCorpusTapped))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    /// CoNLL-U files or folders of them (a whole Universal Dependencies release is one folder),
    /// or CWB-style vertical files: they become one corpus.
    @objc private func importCorpusTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose CoNLL-U files, or a folder of them, to make one corpus."
        panel.prompt = "Import"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }
            let sheet = CorpusImportSheetController(inputs: panel.urls)
            sheet.onImported = { [weak self] in self?.reloadCorpora() }
            presentAsSheet(sheet)
        }
    }

    /// An index folder built elsewhere (with `pando-index`): pick it, or a folder of them.
    /// Korpora links to it; nothing is copied.
    @objc private func addExistingCorpusTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose an index folder, or a folder containing several."
        panel.prompt = "Add"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            addCorpora(at: panel.urls)
        }
    }

    private func addCorpora(at urls: [URL]) {
        var taken = Set(AppSettings.shared.corpusLibraryEntries().map(\.name))
        var problems: [String] = []
        for url in urls {
            if CorpusLibrary.isCorpus(url) {
                do {
                    taken.insert(try CorpusLibrary.link(indexDirectory: url, taken: taken).name)
                } catch {
                    problems.append("\(error)")
                }
            } else {
                let result = CorpusLibrary.linkAll(inDirectory: url, taken: taken)
                taken.formUnion(result.added.map(\.name))
                problems += result.skipped.map { "\($0.name): \($0.reason)" }
                if result.added.isEmpty && result.skipped.isEmpty {
                    problems.append("\u{201C}\(url.lastPathComponent)\u{201D} isn\u{2019}t an index folder and has none inside.")
                }
            }
        }
        reloadCorpora()
        if !problems.isEmpty, let window = view.window {
            let alert = NSAlert()
            alert.messageText = "Some corpora weren\u{2019}t added"
            alert.informativeText = problems.joined(separator: "\n")
            alert.beginSheetModal(for: window)
        }
    }

    private func updateRemoveButton() {
        let index = tableView.selectedRow
        removeButton.isEnabled = rows.indices.contains(index)
    }

    /// Both kinds of corpus are removed the same way: the user chooses
    /// whether the data goes too.
    @objc private func removeSelectedCorpus() {
        let index = tableView.selectedRow
        guard rows.indices.contains(index), let window = view.window else { return }
        let row = rows[index]
        let size = ByteCountFormatter().string(fromByteCount: Int64(row.sizeBytes))
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(row.name)\u{201D}?"
        let text: String
        switch row.entry.origin {
        case .built:
            text = "Korpora built this corpus; its data (\(size)) is in \(row.entry.directory.path). "
                + "Keeping the data moves it to a \u{201C}.Removed\u{201D} folder next to it; "
                + "add it back later with Add Index Folder\u{2026}."
        case .linked(let target):
            text = "This corpus is an index folder outside Korpora (\(target.path), \(size)). "
                + "Keeping the data only takes it off this list; the files stay where they are."
        }
        alert.informativeText = text + " Deleting the data can\u{2019}t be undone."
        alert.addButton(withTitle: "Remove, Keep Data")
        let deleteButton = alert.addButton(withTitle: "Remove and Delete Data")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.remove(row, deleteData: false)
            case .alertSecondButtonReturn: self?.remove(row, deleteData: true)
            default: break
            }
        }
    }

    private func remove(_ row: Row, deleteData: Bool) {
        // Release the warmed pages first: a kept built corpus moves, and a
        // deleted one is gone.
        if AppSettings.shared.isKeepResident(row.name) {
            AppSettings.shared.setKeepResident(false, for: row.name)
            CorpusMemoryResidency.unwarm(directory: row.entry.directory.resolvingSymlinksInPath())
        }
        // Saved subcorpora go with the data; with the data kept, they stay for when it comes back.
        if deleteData { SubcorpusLibrary.deleteAll(of: row.name) }
        let entry = row.entry
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: Error?
            do {
                try CorpusLibrary.remove(entry, deleteData: deleteData)
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run {
                guard let self else { return }
                self.reloadCorpora()
                if let failure, let window = self.view.window {
                    let alert = NSAlert(error: failure)
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    @objc private func minimumFreeChanged() {
        let gb = UInt64(minimumFreeField.stringValue) ?? 10
        AppSettings.shared.minimumFreeMemoryAfterResidency = gb * 1_000_000_000
        refreshMemoryDependentColumn()
    }

    @objc private func keepResidentToggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let directory = rows[sender.tag].entry.directory.resolvingSymlinksInPath()
        let newValue = sender.state == .on
        AppSettings.shared.setKeepResident(newValue, for: rows[sender.tag].name)
        rows[sender.tag].keepResident = newValue

        Task.detached(priority: .utility) {
            if newValue {
                try? await CorpusMemoryResidency.warm(directory: directory)
            } else {
                CorpusMemoryResidency.unwarm(directory: directory)
            }
        }
    }
}

extension CorporaSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    static func sourceTitle(_ origin: CorpusLibrary.Origin) -> String {
        switch origin {
        case .built: return "Built by Korpora"
        case .linked: return "Linked folder"
        }
    }

    static func sourceDetail(_ origin: CorpusLibrary.Origin) -> String {
        switch origin {
        case .built: return "Indexed by Korpora from annotated text."
        case .linked(let target): return "An index folder kept at \(target.path)"
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let corpus = rows[row]
        switch identifier {
        case .name:
            let field = NSTextField(labelWithString: corpus.name)
            field.font = .systemFont(ofSize: 12)
            return field
        case .source:
            let field = NSTextField(labelWithString: Self.sourceTitle(corpus.entry.origin))
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.toolTip = Self.sourceDetail(corpus.entry.origin)
            return field
        case .tokens:
            let field = NSTextField(labelWithString: corpus.entry.tokens.map { $0.formatted() } ?? "\u{2014}")
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.alignment = .right
            return field
        case .size:
            let field = NSTextField(labelWithString: ByteCountFormatter().string(fromByteCount: Int64(corpus.sizeBytes)))
            field.font = .systemFont(ofSize: 12)
            return field
        case .resident:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(keepResidentToggled(_:)))
            checkbox.tag = row
            checkbox.state = corpus.keepResident ? .on : .off
            let fits = CorpusMemoryResidency.canKeepResident(
                sizeBytes: corpus.sizeBytes, currentlyAvailable: CorpusMemoryResidency.availableMemory(),
                minimumFreeAfter: AppSettings.shared.minimumFreeMemoryAfterResidency)
            checkbox.isEnabled = corpus.keepResident || fits
            checkbox.toolTip = checkbox.isEnabled
                ? "Reads the corpus into memory so searches don\u{2019}t wait for the disk."
                : "Not enough free memory to keep this corpus resident without going under the minimum."
            return checkbox
        }
    }
}
