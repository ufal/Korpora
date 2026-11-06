import Cocoa
import KorporaEngine

/// A small horizontal gauge - total vs. currently-available memory - no
/// charting library needed for something this simple.
/// The corpus list: Return renames the selected corpus, as in Finder.
final class CorpusListTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0, let onReturn {
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }
}

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

    private enum Column: String { case name, tokens, source, size, resident, rowHeight, language }

    private let directoryPathLabel = NSTextField(labelWithString: "")
    private let resetDirectoryButton = NSButton(title: "Reset to Default", target: nil, action: nil)
    private let changeDirectoryButton = NSButton(title: "Choose\u{2026}", target: nil, action: nil)
    private let engineNoticeLabel = NSTextField(wrappingLabelWithString: "")
    let tableView = CorpusListTableView()
    private let scrollView = NSScrollView()
    private let memoryBar = MemoryBarView()
    private let memoryLabel = NSTextField(labelWithString: "")
    private let minimumFreeField = NSTextField(string: "")
    private let globalRowHeightCheckbox = NSButton(
        checkboxWithTitle: "Use one row height for every corpus:", target: nil, action: nil)
    private let globalRowHeightField = NSTextField(string: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private static let defaultHint =
        "+ imports annotated text (CoNLL-U) or adds an index folder. Return renames."
    private let removeButton = NSButton(
        image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
        target: nil, action: nil)

    private var rows: [Row] = []
    private var refreshTimer: Timer?
    /// Set by a selection change and cleared by the click that follows: tells a click on a name that selected
    /// the row from one on a row that already was.
    private var selectionChangedSinceClick = false
    private var pendingRename: DispatchWorkItem?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 470))
        // Follow the window when it's resized; without this Auto Layout pins the
        // view to the size it was created with.
        root.autoresizingMask = [.width, .height]

        let directoryLabel = NSTextField(labelWithString: "Corpora built by Korpora are stored in:")
        directoryPathLabel.lineBreakMode = .byTruncatingMiddle
        // A long folder path is shortened in the middle rather than widening the whole Settings window.
        directoryPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryPathLabel.font = .systemFont(ofSize: 11)
        directoryPathLabel.textColor = .secondaryLabelColor
        let showInFinderButton = NSButton(title: "Show in Finder", target: self, action: #selector(showLibraryInFinder))
        let changeDirectoryButton = self.changeDirectoryButton
        changeDirectoryButton.target = self
        changeDirectoryButton.action = #selector(chooseCorporaDirectory)
        changeDirectoryButton.toolTip = "Keep the corpora Korpora builds in another folder, for example on an external disk"
        resetDirectoryButton.target = self
        resetDirectoryButton.action = #selector(resetCorporaDirectory)
        resetDirectoryButton.toolTip = "Go back to the default folder"
        let chooseDirectoryButton = NSStackView(views: [resetDirectoryButton, changeDirectoryButton, showInFinderButton])
        chooseDirectoryButton.orientation = .horizontal
        chooseDirectoryButton.spacing = 6
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
        // The row height and the language of a corpus's table (docs/typography.md): found by looking at the corpus
        // the first time it is opened (shown grey), or typed here.
        let rowHeightColumn = NSTableColumn(identifier: .init(Column.rowHeight.rawValue))
        rowHeightColumn.title = "Row height"
        rowHeightColumn.headerToolTip = "The height of a line in this corpus\u{2019}s tables, in points. Empty: worked out from the scripts the corpus contains"
        rowHeightColumn.minWidth = 92
        rowHeightColumn.width = 92
        rowHeightColumn.resizingMask = .userResizingMask
        let languageColumn = NSTableColumn(identifier: .init(Column.language.rawValue))
        languageColumn.title = "Language"
        languageColumn.headerToolTip = "The language of the text (zh-Hans, zh-Hant, zh-HK, ja, ko, ...), which picks the glyph forms of Chinese, Japanese and Korean characters. Empty: worked out from the corpus"
        languageColumn.minWidth = 80
        languageColumn.width = 85
        languageColumn.resizingMask = .userResizingMask
        for column in [nameColumn, tokensColumn, sourceColumn, sizeColumn, residentColumn, rowHeightColumn, languageColumn] {
            tableView.addTableColumn(column)
        }
        // Name is the flexible column: `fitNameColumn()` gives it the width the others leave.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // The widths the user drags the columns to are remembered. (Not under test: the tests would share them.)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            tableView.autosaveName = "CorporaTable2"
            tableView.autosaveTableColumns = true
        }
        tableView.dataSource = self
        tableView.delegate = self
        // Standard list behaviour: a double-click opens the corpus (its folder in Finder, or the dialog to find it
        // again); a click on the name of a selected row, or Return, renames it; the contextual menu has the rest.
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onReturn = { [weak self] in self?.beginRenamingSelected() }
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu
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
        let addHint = hintLabel
        addHint.stringValue = Self.defaultHint
        addHint.lineBreakMode = .byTruncatingTail
        addHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addHint.font = .systemFont(ofSize: 11)
        addHint.textColor = .secondaryLabelColor

        let memoryTitle = NSTextField(labelWithString: "Memory:")
        memoryLabel.font = .systemFont(ofSize: 11)
        memoryLabel.textColor = .secondaryLabelColor
        let minimumFreeLabel = NSTextField(labelWithString: "Minimum free after keeping a corpus resident:")
        let minimumFreeSuffix = NSTextField(labelWithString: "GB")
        minimumFreeField.target = self
        minimumFreeField.action = #selector(minimumFreeChanged)
        globalRowHeightCheckbox.target = self
        globalRowHeightCheckbox.action = #selector(globalRowHeightToggled)
        globalRowHeightCheckbox.toolTip = "Ignore the row heights above and use this one in every concordance window"
        globalRowHeightField.target = self
        globalRowHeightField.action = #selector(globalRowHeightEdited)
        let globalRowHeightSuffix = NSTextField(labelWithString: "pt")

        let views: [NSView] = [
            directoryLabel, directoryPathLabel, chooseDirectoryButton, engineNoticeLabel,
            scrollView, importButton, removeButton, addHint,
            memoryTitle, memoryBar, memoryLabel,
            minimumFreeLabel, minimumFreeField, minimumFreeSuffix,
            globalRowHeightCheckbox, globalRowHeightField, globalRowHeightSuffix,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        importButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        minimumFreeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        globalRowHeightField.widthAnchor.constraint(equalToConstant: 50).isActive = true
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

            globalRowHeightCheckbox.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 14),
            globalRowHeightCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            globalRowHeightField.centerYAnchor.constraint(equalTo: globalRowHeightCheckbox.centerYAnchor),
            globalRowHeightField.leadingAnchor.constraint(equalTo: globalRowHeightCheckbox.trailingAnchor, constant: 6),
            globalRowHeightSuffix.centerYAnchor.constraint(equalTo: globalRowHeightCheckbox.centerYAnchor),
            globalRowHeightSuffix.leadingAnchor.constraint(equalTo: globalRowHeightField.trailingAnchor, constant: 4),

            memoryTitle.topAnchor.constraint(equalTo: globalRowHeightCheckbox.bottomAnchor, constant: 16),
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
        preferredContentSize = NSSize(width: 840, height: 470)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateDirectoryLabel()
        if let reason = Engines.unavailableReason {
            engineNoticeLabel.stringValue = "The search engine couldn\u{2019}t be loaded, so corpora can\u{2019}t be opened or built: \(reason)"
            engineNoticeLabel.isHidden = false
        }
        minimumFreeField.stringValue = String(AppSettings.shared.minimumFreeMemoryAfterResidency / 1_000_000_000)
        updateGlobalRowHeightControls()
        reloadCorpora()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadCorpora()  // a folder may have moved while the window was closed
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
        rows = AppSettings.shared.corpusLibraryEntries(includingMissing: true)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { entry in
                Row(entry: entry,
                    sizeBytes: entry.isMissing ? 0 : CorpusMemoryResidency.directorySize(entry.directory.resolvingSymlinksInPath()),
                    keepResident: AppSettings.shared.isKeepResident(entry.name))
            }
        tableView.reloadData()
        if let selectedName, let row = rows.firstIndex(where: { $0.name == selectedName }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateRemoveButton()
        updateMemoryBar()
        updateDirectoryLabel()
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
        // The standard folder is made when needed; a chosen one that isn't there (a disk that is not connected)
        // is not made up.
        if CorpusLibrary.baseDirectoryIsAvailable {
            try? FileManager.default.createDirectory(at: CorpusLibrary.baseDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(CorpusLibrary.baseDirectory)
        } else {
            showAlert("The corpora folder isn\u{2019}t available",
                      "\(CorpusLibrary.baseDirectory.path) wasn\u{2019}t found. Is its disk connected?")
        }
    }

    /// The folder shown, and in red when a chosen one is not there (its disk is not connected).
    private func updateDirectoryLabel() {
        let base = CorpusLibrary.baseDirectory
        if CorpusLibrary.baseDirectoryIsAvailable {
            directoryPathLabel.stringValue = base.path
            directoryPathLabel.textColor = .secondaryLabelColor
        } else {
            directoryPathLabel.stringValue = base.path + " \u{2014} not found (is the disk connected?)"
            directoryPathLabel.textColor = .systemRed
        }
        resetDirectoryButton.isHidden = !CorpusLibrary.baseDirectoryIsChosen
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
            self.importCorpus(from: panel.urls)
        }
    }

    /// The import sheet for `urls`, chosen with the panel above or dropped on the app icon (`ConlluDrop`).
    func importCorpus(from urls: [URL]) {
        let sheet = CorpusImportSheetController(inputs: urls)
        sheet.onImported = { [weak self] in self?.reloadCorpora() }
        presentAsSheet(sheet)
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
        var taken = Set(AppSettings.shared.corpusLibraryEntries(includingMissing: true).map(\.name))
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
            ?? AppSettings.shared.corpusLibraryEntries(includingMissing: true).first(where: { $0.name == old }) else {
            throw CorpusLibrary.LibraryError.invalidName("There is no corpus called \u{201C}\(old)\u{201D}.")
        }
        let taken = Set(AppSettings.shared.corpusLibraryEntries(includingMissing: true).map(\.name))
        let renamed = try CorpusLibrary.rename(entry, to: new, taken: taken)
        guard renamed.name != old else { return renamed }
        let wasResident = AppSettings.shared.isKeepResident(old)
        AppSettings.shared.renameKeepResident(from: old, to: renamed.name)
        AppSettings.shared.renameTypography(from: old, to: renamed.name)
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
        switch field.identifier?.rawValue {
        case "rowHeight":
            setRowHeight(field.stringValue, forCorpus: rows[field.tag].name)
            tableView.reloadData(forRowIndexes: [field.tag], columnIndexes: IndexSet(0..<tableView.numberOfColumns))
            return
        case "language":
            setLanguage(field.stringValue, forCorpus: rows[field.tag].name)
            tableView.reloadData(forRowIndexes: [field.tag], columnIndexes: IndexSet(0..<tableView.numberOfColumns))
            return
        default: break
        }
        field.isEditable = false  // editing starts only by a slow click on the selected name, or Return
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
            let taken = Set(AppSettings.shared.corpusLibraryEntries(includingMissing: true).map(\.name))
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
    @objc func removeSelectedCorpus() {
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
                + "Keeping the data moves it to a \u{201C}Removed Corpora\u{201D} folder next to it; "
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
        if deleteData { SubcorpusLibrary.deleteAll(of: row.name); AppSettings.shared.forgetTypography(for: row.name) }
        let entry = row.entry
        Task { @MainActor [weak self] in
            // The removal itself runs off the main actor; only its outcome comes back here.
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    try CorpusLibrary.remove(entry, deleteData: deleteData)
                    return nil
                } catch {
                    return error
                }
            }.value
            guard let self else { return }
            reloadCorpora()
            if let failure, let window = view.window {
                let alert = NSAlert(error: failure)
                alert.beginSheetModal(for: window, completionHandler: nil)
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
        selectionChangedSinceClick = true
        updateRemoveButton()
    }

    static func sourceTitle(_ origin: CorpusLibrary.Origin) -> String {
        switch origin {
        case .built: return "Built"
        case .linked: return "Linked"
        }
    }

    static func sourceTitle(for entry: CorpusLibrary.Entry) -> String {
        entry.isMissing ? "Missing" : sourceTitle(entry.origin)
    }

    static func sourceDetail(for entry: CorpusLibrary.Entry) -> String {
        guard entry.isMissing, case .linked(let target) = entry.origin else { return sourceDetail(entry.origin) }
        return "The index folder isn\u{2019}t at \(target.path) any more. Double-click to find it again, "
            + "or choose Relink\u{2026} in the contextual menu."
    }

    private static func editableCell(identifier: String, row: Int, delegate: NSTextFieldDelegate) -> NSTextField {
        let field = NSTextField(string: "")
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.delegate = delegate
        field.tag = row
        return field
    }

    static func formatPoints(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }

    private func updateGlobalRowHeightControls() {
        let global = AppSettings.shared.globalRowHeight
        globalRowHeightCheckbox.state = global == nil ? .off : .on
        globalRowHeightField.stringValue = Self.formatPoints(global ?? AppSettings.shared.lastGlobalRowHeight)
        globalRowHeightField.isEnabled = global != nil
    }

    @objc private func globalRowHeightToggled() {
        AppSettings.shared.globalRowHeight = globalRowHeightCheckbox.state == .on ? AppSettings.shared.lastGlobalRowHeight : nil
        updateGlobalRowHeightControls()
        tableView.reloadData()
    }

    @objc private func globalRowHeightEdited() {
        if let value = Double(globalRowHeightField.stringValue.replacingOccurrences(of: ",", with: ".")), globalRowHeightCheckbox.state == .on {
            AppSettings.shared.globalRowHeight = min(max(value, CorpusTypographyRules.minimumRowHeight), CorpusTypographyRules.maximumRowHeight)
        }
        updateGlobalRowHeightControls()
    }

    /// A row height typed into a corpus's row: empty goes back to automatic; text that is not a number is put back.
    func setRowHeight(_ text: String, forCorpus name: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("auto") {
            AppSettings.shared.updateTypography(for: name) { $0.rowHeight = nil }
        } else if let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
            let clamped = min(max(value, CorpusTypographyRules.minimumRowHeight), CorpusTypographyRules.maximumRowHeight)
            AppSettings.shared.updateTypography(for: name) { $0.rowHeight = clamped }
        }
    }

    /// A language typed into a corpus's row: empty or `auto` goes back to automatic.
    func setLanguage(_ text: String, forCorpus name: String) {
        let language = CorpusTypographyRules.normalizedLanguage(text)
        AppSettings.shared.updateTypography(for: name) { $0.language = language }
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
            // Editable in place, as in Finder: click the name of a selected row, or press Return (a double-click
            // opens the corpus instead). Editing is switched on only then, so that other clicks don't start it.
            let field = NSTextField(string: corpus.name)
            field.isEditable = false
            field.isSelectable = false
            field.textColor = corpus.entry.isMissing ? .secondaryLabelColor : .labelColor
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.delegate = self
            field.tag = row
            field.toolTip = "Click the name of a selected corpus, or press Return, to rename it; double-click to open it"
            return field
        case .source:
            let field = NSTextField(labelWithString: Self.sourceTitle(for: corpus.entry))
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.toolTip = Self.sourceDetail(for: corpus.entry)
            guard corpus.entry.isMissing else { return field }
            // A warning sign before the word, for a corpus whose folder is gone.
            let icon = NSImageView(image: NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Missing") ?? NSImage())
            icon.contentTintColor = .systemOrange
            icon.toolTip = field.toolTip
            icon.setAccessibilityLabel("Missing: the index folder was not found")
            let stack = NSStackView(views: [icon, field])
            stack.orientation = .horizontal
            stack.spacing = 3
            return stack
        case .tokens:
            let field = NSTextField(labelWithString: corpus.entry.tokens.map { $0.formatted() } ?? "\u{2014}")
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.alignment = .right
            return field
        case .size:
            let field = NSTextField(labelWithString: corpus.entry.isMissing
                ? "\u{2014}" : ByteCountFormatter().string(fromByteCount: Int64(corpus.sizeBytes)))
            field.font = .systemFont(ofSize: 12)
            return field
        case .rowHeight:
            let typography = AppSettings.shared.typography(for: corpus.name)
            let field = Self.editableCell(identifier: "rowHeight", row: row, delegate: self)
            field.stringValue = typography.rowHeight.map(Self.formatPoints) ?? ""
            if let global = AppSettings.shared.globalRowHeight {
                field.isEnabled = false
                field.placeholderString = "global \(Self.formatPoints(global))"
            } else {
                let automatic = CorpusTypographyService.automaticRowHeight(for: typography)
                field.placeholderString = automatic.map { "auto (\(Self.formatPoints($0)))" } ?? "auto"
            }
            field.toolTip = "Points per line in this corpus\u{2019}s tables. Empty: from the scripts the corpus contains."
            return field
        case .language:
            let typography = AppSettings.shared.typography(for: corpus.name)
            let field = Self.editableCell(identifier: "language", row: row, delegate: self)
            field.stringValue = typography.language ?? ""
            field.placeholderString = typography.scan?.language.map { "auto (\($0))" } ?? "auto"
            field.toolTip = "The language (zh-Hans, zh-Hant, zh-HK, ja, ko, ...) that picks the glyph forms of Chinese, Japanese "
                + "and Korean characters. Empty: worked out from the corpus."
            return field
        case .resident:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(keepResidentToggled(_:)))
            checkbox.tag = row
            checkbox.state = corpus.keepResident ? .on : .off
            let fits = CorpusMemoryResidency.canKeepResident(
                sizeBytes: corpus.sizeBytes, currentlyAvailable: CorpusMemoryResidency.availableMemory(),
                minimumFreeAfter: AppSettings.shared.minimumFreeMemoryAfterResidency)
            checkbox.isEnabled = !corpus.entry.isMissing && (corpus.keepResident || fits)
            checkbox.toolTip = corpus.entry.isMissing
                ? "The index folder is missing."
                : checkbox.isEnabled
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

// MARK: Opening, renaming, relinking, bringing in

extension CorporaSettingsViewController: NSMenuDelegate {
    private var selectedRow: Row? {
        rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow] : nil
    }

    /// A click on the name of a row that was already selected renames it, after the double-click interval so
    /// that a double-click (which opens the corpus) doesn't start an edit first.
    @objc private func rowClicked() {
        defer { selectionChangedSinceClick = false }
        pendingRename?.cancel()
        guard !selectionChangedSinceClick, tableView.clickedColumn == 0, rows.indices.contains(tableView.clickedRow),
              tableView.clickedRow == tableView.selectedRow else { return }
        let work = DispatchWorkItem { [weak self] in self?.beginRenamingSelected() }
        pendingRename = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    @objc private func rowDoubleClicked() {
        pendingRename?.cancel()
        guard rows.indices.contains(tableView.clickedRow) else { return }
        tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
        openSelectedCorpus()
    }

    func beginRenamingSelected() {
        let index = tableView.selectedRow
        guard rows.indices.contains(index),
              let field = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTextField else { return }
        field.isEditable = true
        field.isSelectable = true
        view.window?.makeFirstResponder(field)
    }

    /// Where the corpus's index is: for a linked one, the folder the link leads to.
    private func location(of row: Row) -> URL {
        if case .linked(let target) = row.entry.origin { return target }
        return row.entry.directory
    }

    /// Double-click: the corpus's folder in Finder; a corpus whose folder is gone asks where it went.
    @objc func openSelectedCorpus() {
        guard let row = selectedRow else { return }
        if row.entry.isMissing {
            relinkSelected()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([location(of: row)])
        }
    }

    @objc func relinkSelected() {
        guard let row = selectedRow, row.entry.isLinked, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the index folder of \u{201C}\(row.name)\u{201D} (the one with corpus.info in it)."
        panel.prompt = "Relink"
        // Start where it used to be, or at the nearest folder that still exists.
        var start = location(of: row).deletingLastPathComponent()
        while start.path != "/", !FileManager.default.fileExists(atPath: start.path) { start.deleteLastPathComponent() }
        panel.directoryURL = start
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            relink(row, to: url)
        }
    }

    private func relink(_ row: Row, to url: URL) {
        let wasResident = AppSettings.shared.isKeepResident(row.name)
        if wasResident { CorpusMemoryResidency.unwarm(directory: row.entry.directory.resolvingSymlinksInPath()) }
        do {
            let entry = try CorpusLibrary.relink(row.entry, to: url)
            if wasResident {
                let directory = entry.directory.resolvingSymlinksInPath()
                Task.detached(priority: .utility) { try? await CorpusMemoryResidency.warm(directory: directory) }
            }
        } catch {
            showAlert("\u{201C}\(row.name)\u{201D} couldn\u{2019}t be relinked", "\(error)")
        }
        reloadCorpora()
    }

    /// Makes a linked corpus a built one: its index is copied (or moved) into Korpora's own folder.
    @objc func bringSelectedIn() {
        guard let row = selectedRow, row.entry.isLinked, !row.entry.isMissing, let window = view.window else { return }
        let size = ByteCountFormatter().string(fromByteCount: Int64(row.sizeBytes))
        let alert = NSAlert()
        alert.messageText = "Bring \u{201C}\(row.name)\u{201D} into Korpora?"
        alert.informativeText = "The index (\(size)) is now kept at \(location(of: row).path). "
            + "Copying puts a second one in Korpora\u{2019}s own folder and leaves the original alone; "
            + "moving takes it out of its old place. Either way, the name, subcorpora and history stay."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response != .alertThirdButtonReturn, response != .cancel else { return }
            bringIn(row, copy: response == .alertFirstButtonReturn)
        }
    }

    private func bringIn(_ row: Row, copy: Bool) {
        if AppSettings.shared.isKeepResident(row.name) {
            CorpusMemoryResidency.unwarm(directory: row.entry.directory.resolvingSymlinksInPath())
        }
        let entry = row.entry
        runWithProgress(
            headline: "\(copy ? "Copying" : "Moving") \u{201C}\(row.name)\u{201D} into Korpora",
            work: { report in try CorpusLibrary.bringIn(entry, copy: copy, onProgress: report) }
        ) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .failure(let error) where error is CancellationError:
                break  // stopped by the user: nothing was changed
            case .failure(let error):
                showAlert("\u{201C}\(row.name)\u{201D} couldn\u{2019}t be brought into Korpora", "\(error)")
            case .success(let built):
                if AppSettings.shared.isKeepResident(row.name) {
                    let directory = built.directory
                    Task.detached(priority: .utility) { try? await CorpusMemoryResidency.warm(directory: directory) }
                }
            }
            reloadCorpora()
        }
    }

    /// Runs `work` off the main actor with a progress sheet (Cancel stops it), shown only if it takes more than a
    /// moment: a move within one disk is instant. `work` gets a function to report progress to.
    func runWithProgress<T: Sendable>(
        headline: String,
        work: @escaping @Sendable (@escaping @Sendable (CorpusLibrary.TransferProgress) -> Void) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let sheet = TransferProgressSheetController(headline: headline)
        var presented = false
        var finished = false
        setBusy(true)
        let report: @Sendable (CorpusLibrary.TransferProgress) -> Void = { progress in
            DispatchQueue.main.async { MainActor.assumeIsolated { sheet.update(progress) } }
        }
        let task = Task.detached(priority: .userInitiated) { Result { try work(report) } }
        sheet.onCancel = { task.cancel() }
        let present = DispatchWorkItem { [weak self] in
            guard let self, !finished else { return }
            presented = true
            presentAsSheet(sheet)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: present)
        Task { @MainActor [weak self] in
            let outcome = await task.value
            finished = true
            present.cancel()
            if presented { sheet.dismiss(nil) }
            self?.setBusy(false)
            completion(outcome)
        }
    }

    func showAlert(_ title: String, _ text: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: Contextual menu

    /// The commands of the selected corpus (a right-click selects the row first). Rare ones live here and not in
    /// the toolbar of the list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if tableView.clickedRow >= 0, tableView.clickedRow != tableView.selectedRow {
            tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
        }
        guard let row = selectedRow else { return }
        let linked = row.entry.isLinked, missing = row.entry.isMissing
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
        }
        add("Show in Finder", #selector(openSelectedCorpus), enabled: !missing)
        add("Rename", #selector(renameFromMenu))
        if linked {
            menu.addItem(.separator())
            add("Relink\u{2026}", #selector(relinkSelected))
            add("Bring into Korpora\u{2026}", #selector(bringSelectedIn), enabled: !missing)
        }
        menu.addItem(.separator())
        add("Remove\u{2026}", #selector(removeFromMenu))
    }

    @objc private func renameFromMenu() { beginRenamingSelected() }
    @objc private func removeFromMenu() { removeSelectedCorpus() }
}

// MARK: The folder for built corpora

extension CorporaSettingsViewController {
    @objc func chooseCorporaDirectory() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where Korpora keeps the corpora it builds, for example one on an external disk."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            useCorporaDirectory(url)
        }
    }

    @objc func resetCorporaDirectory() {
        useCorporaDirectory(CorpusLibrary.defaultBaseDirectory, isStandard: true)
    }

    /// Switches to `folder`; when corpora are in the current folder, first asks whether to move them along or
    /// leave them where they are.
    func useCorporaDirectory(_ folder: URL, isStandard: Bool = false) {
        let current = CorpusLibrary.baseDirectory
        guard folder.resolvingSymlinksInPath().path != current.resolvingSymlinksInPath().path else { return }
        do {
            if isStandard {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try CorpusLibrary.validateNewBaseDirectory(folder, replacing: current)
        } catch {
            showAlert("That folder can\u{2019}t be used", "\(error)")
            return
        }
        let existing = CorpusLibrary.baseDirectoryIsAvailable ? CorpusLibrary.builtCorpora(in: current) : []
        guard !existing.isEmpty, let window = view.window else {
            switchCorporaDirectory(to: folder, isStandard: isStandard)
            return
        }
        let size = ByteCountFormatter().string(
            fromByteCount: Int64(existing.reduce(0) { $0 + CorpusMemoryResidency.directorySize($1.directory) }))
        let alert = NSAlert()
        alert.messageText = existing.count == 1
            ? "Move the corpus \u{201C}\(existing[0].name)\u{201D} to the new folder?"
            : "Move your \(existing.count) corpora to the new folder?"
        alert.informativeText = "\(existing.count == 1 ? "It is" : "They are") in \(current.path) (\(size)). "
            + "Moving \(existing.count == 1 ? "it" : "them") to \(folder.path) keeps "
            + "\(existing.count == 1 ? "it" : "them") in the list; to another disk this can take a while. "
            + "If you leave \(existing.count == 1 ? "it" : "them"), Korpora stops listing "
            + "\(existing.count == 1 ? "it" : "them"): \(existing.count == 1 ? "it stays" : "they stay") in the old folder "
            + "and \(existing.count == 1 ? "comes" : "come") back if you choose that folder again."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Leave Them")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: moveCorpora(existing, from: current, to: folder, isStandard: isStandard)
            case .alertSecondButtonReturn: switchCorporaDirectory(to: folder, isStandard: isStandard)
            default: break
            }
        }
    }

    private func switchCorporaDirectory(to folder: URL, isStandard: Bool) {
        AppSettings.shared.corporaDirectory = isStandard ? nil : folder
        reloadCorpora()
    }

    private func moveCorpora(_ existing: [CorpusLibrary.Entry], from old: URL, to new: URL, isStandard: Bool) {
        let resident = existing.map(\.name).filter { AppSettings.shared.isKeepResident($0) }
        for entry in existing where resident.contains(entry.name) {
            CorpusMemoryResidency.unwarm(directory: entry.directory)
        }
        runWithProgress(
            headline: "Moving \(existing.count == 1 ? "the corpus" : "\(existing.count) corpora") to \(new.lastPathComponent)",
            work: { report in CorpusLibrary.moveBuiltCorpora(from: old, to: new, onProgress: report) }
        ) { [weak self] outcome in
            guard let self, case .success(let result) = outcome else { return }
            if result.failed.isEmpty && !result.cancelled {
                switchCorporaDirectory(to: new, isStandard: isStandard)
                for name in resident {
                    guard let directory = CorpusLibrary.directory(forName: name) else { continue }
                    Task.detached(priority: .utility) { try? await CorpusMemoryResidency.warm(directory: directory) }
                }
                if !result.skipped.isEmpty {
                    showAlert("Some corpora stayed in the old folder",
                              "The new folder already has \(result.skipped.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")), "
                              + "so \(result.skipped.count == 1 ? "that one was" : "those were") not moved; the ones in the new folder are used.")
                }
            } else {
                // Stay with the old folder: what was not moved is still there. What was moved is in the new one.
                let why = result.cancelled
                    ? "Stopped. " : result.failed.map { "\($0.name): \($0.reason)" }.joined(separator: "\n") + "\n\n"
                showAlert(result.cancelled ? "The move was stopped" : "Not all corpora could be moved",
                          "\(why)Korpora still uses \(old.path). \(result.moved.count) corpora were moved to "
                          + "\(new.path) already; choose that folder again to finish.")
                reloadCorpora()
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        tableView.isEnabled = !busy
        resetDirectoryButton.isEnabled = !busy
        changeDirectoryButton.isEnabled = !busy
    }
}
