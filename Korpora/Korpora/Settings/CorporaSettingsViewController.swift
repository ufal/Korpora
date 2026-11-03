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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 440))
        // Follow the window when it's resized; without this Auto Layout pins the
        // view to the size it was created with.
        root.autoresizingMask = [.width, .height]

        let directoryLabel = NSTextField(labelWithString: "Corpora built by Korpora are stored in:")
        directoryPathLabel.lineBreakMode = .byTruncatingMiddle
        // A long folder path is shortened in the middle rather than widening the whole Settings window.
        directoryPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        // The fixed columns are as narrow as their own heading and content allow, so the Name column - the one
        // that needs room - gets nearly all of the rest.
        let tokensColumn = NSTableColumn(identifier: .init(Column.tokens.rawValue))
        tokensColumn.title = "Tokens"
        tokensColumn.minWidth = 95
        tokensColumn.width = 100
        tokensColumn.resizingMask = .userResizingMask
        let sourceColumn = NSTableColumn(identifier: .init(Column.source.rawValue))
        sourceColumn.title = "Source"
        sourceColumn.minWidth = 80
        sourceColumn.width = 80
        sourceColumn.resizingMask = .userResizingMask
        let sizeColumn = NSTableColumn(identifier: .init(Column.size.rawValue))
        sizeColumn.title = "On disk"
        sizeColumn.minWidth = 80
        sizeColumn.width = 80
        sizeColumn.resizingMask = .userResizingMask
        // "Keep in Memory" was the widest heading by far; the checkbox under it is explained by a tooltip.
        let residentColumn = NSTableColumn(identifier: .init(Column.resident.rawValue))
        residentColumn.title = "In Memory"
        residentColumn.headerToolTip = "Keep the corpus in memory, so searches don\u{2019}t wait for the disk"
        residentColumn.headerCell.alignment = .center
        residentColumn.minWidth = 95
        residentColumn.width = 95
        residentColumn.resizingMask = .userResizingMask
        for column in [nameColumn, tokensColumn, sourceColumn, sizeColumn, residentColumn] {
            tableView.addTableColumn(column)
        }
        // Name is the flexible column: `fitNameColumn()` gives it the width the others leave.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // The widths the user drags the columns to are remembered. (Not under test: the tests would share them.)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            tableView.autosaveName = "CorporaTable"
            tableView.autosaveTableColumns = true
        }
        tableView.dataSource = self
        tableView.delegate = self
        // AppKit's default 17-point gap between columns would take 85 points of a five-column list.
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
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
            "+ imports annotated text (CoNLL-U) or adds an index folder. Click a name to rename it.")
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
        preferredContentSize = NSSize(width: 680, height: 440)
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
            self?.refreshOnTimer()
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
        NotificationCenter.default.post(name: AppSettings.corporaDidChangeNotification, object: nil)
    }

    var selectedCorpusName: String? {
        rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow].name : nil
    }

    /// Whether a corpus still fits in free memory changes as memory does, so
    /// the "Keep in Memory" checkboxes are refreshed on a timer. Only that
    /// column: `reloadData()` would clear the selection, and with it the
    /// chance to click "\u{2212}" (found in the macOS 15 smoke test of 0.2).
    /// The first time the table has its real width the narrow columns get their designed widths (unless the user's
    /// own were saved); from then on, every layout gives the Name column whatever the others leave. AppKit's own
    /// "first column only" autoresizing left a gap on first layout and spread the rest over every column.
    private var appliedInitialWidths = false
    private static let designedWidths: [Column: CGFloat] = [.tokens: 100, .source: 80, .size: 80, .resident: 95]

    override func viewDidLayout() {
        super.viewDidLayout()
        guard scrollView.frame.width > 200 else { return }
        if !appliedInitialWidths {
            appliedInitialWidths = true
            let saved = tableView.autosaveName.flatMap {
                UserDefaults.standard.object(forKey: "NSTableView Columns \($0)")
            }
            if saved == nil {
                for column in tableView.tableColumns {
                    guard let kind = Column(rawValue: column.identifier.rawValue),
                          let width = Self.designedWidths[kind] else { continue }
                    column.width = width
                }
            }
        }
        fitNameColumn()
    }

    func fitNameColumn() {
        guard let name = tableView.tableColumns.first else { return }
        let spacing = tableView.intercellSpacing.width
        let others = tableView.tableColumns.dropFirst().reduce(CGFloat(0)) { $0 + $1.width + spacing }
        let width = max(scrollView.contentSize.width - others - spacing, name.minWidth)
        if abs(name.width - width) > 0.5 { name.width = width }
    }

    /// Whether a name in the list is being edited right now: its field is the window's first responder
    /// (the window's field editor), which is not the table itself.
    var isEditingName: Bool {
        guard let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as? NSView)?.isDescendant(of: tableView) == true
    }

    /// Runs every two seconds. Not while a name is being typed: reloading cells of the row being edited ends
    /// the edit and commits what is typed so far (a corpus once got renamed to "S" that way).
    func refreshOnTimer() {
        guard !isEditingName else { return }
        updateMemoryBar()
        refreshMemoryDependentColumn()
    }

    func refreshMemoryDependentColumn() {
        guard !isEditingName else { return }
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
        // One index folder: ask what to call it. (Several at once take their folder names; rename them in the list.)
        if urls.count == 1, CorpusLibrary.isCorpus(urls[0]) {
            linkAskingForName(urls[0]) { [weak self] _ in self?.reloadCorpora() }
            return
        }
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

    // MARK: Naming

    /// Gives the corpus called `old` the name `new`, and moves everything kept under the old name along
    /// (Keep in Memory, saved subcorpora, search history). Throws without changing anything if the name
    /// is empty, unusable, or taken.
    @discardableResult
    func renameCorpus(named old: String, to new: String) throws -> CorpusLibrary.Entry {
        guard let entry = rows.first(where: { $0.name == old })?.entry
            ?? AppSettings.shared.corpusLibraryEntries().first(where: { $0.name == old }) else {
            throw CorpusLibrary.LibraryError.invalidName("There is no corpus called \u{201C}\(old)\u{201D}.")
        }
        let taken = Set(AppSettings.shared.corpusLibraryEntries().map(\.name))
        let renamed = try CorpusLibrary.rename(entry, to: new, taken: taken)
        guard renamed.name != old else { return renamed }
        let wasResident = AppSettings.shared.isKeepResident(old)
        AppSettings.shared.renameKeepResident(from: old, to: renamed.name)
        SubcorpusLibrary.rename(corpus: old, to: renamed.name)
        QueryHistoryStore.renameCorpus(from: old, to: renamed.name)
        reloadCorpora()
        if wasResident {
            // A built corpus's folder moved: read it into memory again from where it is now.
            let directory = renamed.directory.resolvingSymlinksInPath()
            Task.detached(priority: .utility) { try? await CorpusMemoryResidency.warm(directory: directory) }
        }
        return renamed
    }

    /// A name typed into the list was committed: rename, or say why not and put the old name back.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, rows.indices.contains(field.tag) else { return }
        let old = rows[field.tag].name
        do {
            try renameCorpus(named: old, to: field.stringValue)
        } catch {
            field.stringValue = old
            if let window = view.window {
                let alert = NSAlert()
                alert.messageText = "\u{201C}\(old)\u{201D} couldn\u{2019}t be renamed"
                alert.informativeText = "\(error)"
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// Links one index folder, first asking what to call it: the folder is often named `idx`, which says
    /// nothing in a list of corpora. Asks again (with the reason) if the name can't be used.
    private func linkAskingForName(_ url: URL, suggestion: String? = nil, problem: String? = nil,
                                   then done: @escaping (Error?) -> Void) {
        guard let window = view.window else { done(nil); return }
        let alert = NSAlert()
        alert.messageText = "Name this corpus"
        alert.informativeText = (problem.map { $0 + "\n\n" } ?? "")
            + "The name appears in Korpora\u{2019}s lists. The folder \u{201C}\(url.lastPathComponent)\u{201D} keeps its own name."
        let field = NSTextField(string: suggestion ?? CorpusLibrary.suggestedName(forIndex: url))
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { done(nil); return }
            let taken = Set(AppSettings.shared.corpusLibraryEntries().map(\.name))
            do {
                try CorpusLibrary.link(indexDirectory: url, name: field.stringValue, taken: taken)
                done(nil)
            } catch {
                self.linkAskingForName(url, suggestion: field.stringValue, problem: "\(error)", then: done)
            }
        }
        alert.window.makeFirstResponder(field)
        field.selectText(nil)
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

extension CorporaSettingsViewController: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    static func sourceTitle(_ origin: CorpusLibrary.Origin) -> String {
        switch origin {
        case .built: return "Built"
        case .linked: return "Linked"
        }
    }

    static func sourceDetail(_ origin: CorpusLibrary.Origin) -> String {
        switch origin {
        case .built: return "Built by Korpora from annotated text."
        case .linked(let target): return "Linked: an index folder kept at \(target.path)"
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }) else { return nil }
        let corpus = rows[row]
        switch identifier {
        case .name:
            // Editable in place, as in Finder: select the row, then click the name (or double-click it).
            let field = NSTextField(string: corpus.name)
            field.isEditable = true
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            field.tag = row
            field.toolTip = "Click the name of a selected corpus, or double-click it, to rename it"
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
            // Centred under its heading.
            let cell = NSView()
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}
