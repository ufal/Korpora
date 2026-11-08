import Cocoa
import KorporaEngine

/// The sheet behind the toolbar's Frequencies button (docs/frequency-composer.md): the query with its tokens drawn
/// as coloured, named nodes, the first hit in the same colours (with arrows to the others), and a table of what to
/// count. Click a node, pick an attribute, and it becomes a line of the table, where it can be put in order, sorted,
/// folded for case or removed.
final class FrequencyComposerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// The user's query, as typed.
    var query = ""
    /// The corpus's attributes and structures.
    var infoProvider: (() async throws -> CorpusInfo)?
    /// How many hits there are to step through.
    var hitCount = 0
    /// Hit `n` as words with the words its nodes matched, given the attributes to read for each.
    var hitProvider: ((Int, [String]) async throws -> HitNodes)?
    var onRun: ((_ fields: [FrequencyField], _ sortKeys: [FrequencySortKey], _ minFrequency: Int, _ nodes: QueryNodes) -> Void)?

    var model = FrequencyComposerModel()
    private(set) var nodes = QueryNodes("")

    private var positional: [String] = []
    private var properties: [String] = []
    private var hit: HitNodes?
    private var hitIndex = 0
    private var hitGeneration = 0
    /// True once the corpus's attributes and the first hit have been asked for.
    private(set) var hasLoaded = false
    private weak var popover: NSPopover?

    let queryStrip = NodeStripView()
    let hitStrip = NodeStripView()
    private let table = NSTableView()
    let previousButton = NSButton()
    let nextButton = NSButton()
    let counterLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    let minFrequencyField = NSTextField(string: "1")
    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let runButton = NSButton(title: "Count", target: nil, action: nil)

    private static let dragType = NSPasteboard.PasteboardType("cz.cuni.mff.ufal.korpora.composer-row")
    private enum Column: String, CaseIterable { case node, attribute, ignoreCase, sort, remove }

    // MARK: View

    override func loadView() {
        nodes = QueryNodes(query)

        let title = NSTextField(labelWithString: "Frequency Distribution")
        title.font = .boldSystemFont(ofSize: 13)
        let help = NSTextField(wrappingLabelWithString:
            "Click a node in the query or in the hit, and pick the attribute to count. Add as many as you like: the table counts each combination.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        queryStrip.accessibilityDescription = "Query"
        hitStrip.accessibilityDescription = "First hit"
        queryStrip.onPick = { [weak self] node, rect in self?.showPicker(node: node, from: self?.queryStrip, rect: rect) }
        hitStrip.onPick = { [weak self] node, rect in self?.showPicker(node: node, from: self?.hitStrip, rect: rect) }

        let queryCaption = caption("Query")
        let hitCaption = caption("Hit")
        configureArrow(previousButton, symbol: "chevron.left", label: "Previous hit", action: #selector(previousHit))
        configureArrow(nextButton, symbol: "chevron.right", label: "Next hit", action: #selector(nextHit))
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counterLabel.textColor = .secondaryLabelColor
        let hitHeader = NSStackView(views: [hitCaption, previousButton, nextButton, counterLabel])
        hitHeader.orientation = .horizontal
        hitHeader.spacing = 6

        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isHidden = true
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let countCaption = caption("Count")
        configureTable()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tableHeight = scroll.heightAnchor.constraint(equalToConstant: 168)
        tableHeight.priority = .defaultHigh      // the table gives way before anything is clipped
        tableHeight.isActive = true

        addButton.setAccessibilityLabel("Add an attribute")
        let minLabel = NSTextField(labelWithString: "Min. frequency:")
        minFrequencyField.translatesAutoresizingMaskIntoConstraints = false
        minFrequencyField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let spacer = NSView()
        let tableFooter = NSStackView(views: [addButton, spacer, minLabel, minFrequencyField])
        tableFooter.orientation = .horizontal
        tableFooter.spacing = 8

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        runButton.target = self
        runButton.action = #selector(runTapped)
        runButton.keyEquivalent = "\r"
        runButton.bezelStyle = .rounded
        let buttonSpacer = NSView()
        let buttons = NSStackView(views: [buttonSpacer, cancel, runButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [
            title, help, queryCaption, queryStrip, hitHeader, hitStrip, noteLabel, countCaption, scroll, tableFooter,
            errorLabel, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(10, after: help)
        stack.setCustomSpacing(10, after: queryStrip)
        stack.setCustomSpacing(10, after: hitStrip)
        stack.setCustomSpacing(12, after: noteLabel)
        for wide in [help, queryStrip, hitStrip, noteLabel, scroll, tableFooter, errorLabel, buttons] as [NSView] {
            wide.translatesAutoresizingMaskIntoConstraints = false
            wide.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 560))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 780),
        ])
        view = root
        preferredContentSize = NSSize(width: 780, height: 560)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showQuery()
        updateHitControls()
        rebuildAddMenu()
        // The sheet is as tall as what it holds (the strips wrap at this width).
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 780, height: max(view.fittingSize.height, 420))
        Task { @MainActor [weak self] in await self?.start() }
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureArrow(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func configureTable() {
        let titles: [Column: (String, CGFloat)] = [
            .node: ("Node", 90), .attribute: ("Attribute", 240), .ignoreCase: ("Ignore case", 88), .sort: ("Order", 60), .remove: ("", 36),
        ]
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = titles[column]?.0 ?? ""
            tableColumn.width = titles[column]?.1 ?? 60
            if column == .attribute { tableColumn.resizingMask = .autoresizingMask } else { tableColumn.resizingMask = [] }
            table.addTableColumn(tableColumn)
        }
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("What to count, in order")
    }

    // MARK: Loading

    private func start() async {
        do {
            guard let info = try await infoProvider?() else { throw CancellationError() }
            positional = info.attributes
            properties = info.structures.flatMap { structure in structure.attributes.map { "\(structure.name).\($0)" } }
        } catch {
            show(error: error)
        }
        rebuildAddMenu()
        addDefaultLine()
        table.reloadData()
        updateRunButton()
        await loadHit(0)
        hasLoaded = true
    }

    /// A first line, so Count does something at once: the form of the query's first node.
    private func addDefaultLine() {
        guard model.isEmpty, let node = nodes.nodes.first(where: \.isPickable) else { return }
        let attribute = ["form", "word"].first(where: positional.contains) ?? positional.first
        if let attribute { model.add(.node(node.name, attribute: attribute)) }
    }

    private func loadHit(_ index: Int) async {
        guard hitCount > 0, let hitProvider else {
            hit = nil
            showHit()
            return
        }
        hitGeneration += 1
        let generation = hitGeneration
        let wanted = max(0, min(index, hitCount - 1))
        do {
            let fetched = try await hitProvider(wanted, positional)
            guard generation == hitGeneration else { return }
            hit = fetched
            hitIndex = wanted
        } catch {
            guard generation == hitGeneration else { return }
            hit = nil
            hitIndex = wanted
            noteLabel.stringValue = "This hit can\u{2019}t be shown: \(error.localizedDescription)"
            noteLabel.isHidden = false
        }
        showHit()
    }

    // MARK: The strips

    private func showQuery() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = NSMutableAttributedString(string: query, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: NodeStripView.paragraphStyle(),
        ])
        var spans: [NodeStripView.Span] = []
        for node in nodes.nodes {
            var range = node.range
            if let mark = node.repeatMark { range.length += (mark as NSString).length }
            let tip = node.isPickable
                ? "Node \(node.name): click to count one of its attributes."
                : "Node \(node.name) can match several words or none, so a frequency can\u{2019}t be taken from it."
            spans.append(.init(range: range, node: node.index, name: node.name, pickable: node.isPickable, toolTip: tip))
        }
        queryStrip.setContent(text, spans: spans)
        if let reason = nodes.unsupportedReason {
            noteLabel.stringValue = "\(reason) Its tokens can\u{2019}t be picked; text and document properties can still be counted."
            noteLabel.isHidden = false
        }
    }

    private func showHit() {
        updateHitControls()
        guard let hit else {
            hitStrip.setContent(NSAttributedString(string: hitCount == 0 ? "No hits to show." : "", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: NodeStripView.paragraphStyle(),
            ]), spans: [])
            return
        }
        let font = NSFont.systemFont(ofSize: 13)
        let text = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (index, word) in hit.words.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            let range = NSRange(location: text.length, length: (word as NSString).length)
            let inHit = hit.matchRange.contains(index)
            text.append(NSAttributedString(string: word, attributes: [
                .font: font, .foregroundColor: inHit ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]))
            ranges.append(range)
        }
        text.addAttribute(.paragraphStyle, value: NodeStripView.paragraphStyle(), range: NSRange(location: 0, length: text.length))

        var spans: [NodeStripView.Span] = []
        var note: String?
        if nodes.nodes.isEmpty {
            // Nothing to colour.
        } else if hit.tokens.count == nodes.nodes.count {
            for (node, token) in zip(nodes.nodes, hit.tokens) where ranges.indices.contains(token.wordIndex) {
                spans.append(.init(range: ranges[token.wordIndex], node: node.index, name: node.name, pickable: node.isPickable,
                                   toolTip: node.isPickable ? "Node \(node.name): click to count one of its attributes." : nil))
            }
        } else {
            note = "The words of this hit can\u{2019}t be matched to the query\u{2019}s tokens (some are optional or repeated). Click the nodes in the query above."
        }
        hitStrip.setContent(text, spans: spans)
        if let note { noteLabel.stringValue = note; noteLabel.isHidden = false } else if nodes.unsupportedReason == nil { noteLabel.isHidden = true }
    }

    private func updateHitControls() {
        previousButton.isEnabled = hitCount > 1 && hitIndex > 0
        nextButton.isEnabled = hitCount > 1 && hitIndex < hitCount - 1
        counterLabel.stringValue = hitCount == 0 ? "" : "\(hitIndex + 1) of \(hitCount.formatted())"
    }

    @objc func previousHit() { Task { @MainActor in await loadHit(hitIndex - 1) } }
    @objc func nextHit() { Task { @MainActor in await loadHit(hitIndex + 1) } }

    // MARK: Picking

    private func nodeName(at index: Int) -> String? { nodes.nodes.indices.contains(index) ? nodes.nodes[index].name : nil }

    private func showPicker(node: Int, from strip: NodeStripView?, rect: NSRect) {
        guard let strip, let name = nodeName(at: node), !positional.isEmpty else { return }
        popover?.close()
        let samples: [String: String] = {
            guard let hit, hit.tokens.count == nodes.nodes.count else { return [:] }
            return hit.tokens[node].attributes
        }()
        let entries = positional.map { NodeAttributePicker.Entry(name: $0, sample: samples[$0]) }
        let picker = NodeAttributePicker(heading: "Node \(name)", color: NodeColors.color(at: node), entries: entries) { [weak self] attribute in
            self?.popover?.close()
            self?.pick(node: name, attribute: attribute)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.show(relativeTo: rect, of: strip, preferredEdge: .maxY)
        self.popover = popover
    }

    func pick(node: String, attribute: String) {
        add(.node(node, attribute: attribute))
    }

    private func add(_ kind: ComposerRow.Kind) {
        errorLabel.isHidden = true
        if model.add(kind) {
            table.reloadData()
            if let row = model.rows.firstIndex(where: { $0.kind == kind }) { table.scrollRowToVisible(row) }
        } else if let row = model.rows.firstIndex(where: { $0.kind == kind }) {
            // Already there: show where.
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            NSSound.beep()
        }
        updateRunButton()
    }

    /// The "Add" pull-down: the same choices without the mouse on a node (also what VoiceOver reaches).
    private func rebuildAddMenu() {
        let menu = addButton.menu ?? NSMenu()
        menu.removeAllItems()
        menu.addItem(withTitle: "Add\u{2026}", action: nil, keyEquivalent: "")
        for node in nodes.nodes where node.isPickable {
            let item = NSMenuItem(title: "Node \(node.name)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for attribute in positional {
                let entry = NSMenuItem(title: attribute, action: #selector(addFromMenu(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = ComposerRow.Kind.node(node.name, attribute: attribute) as Any
                sub.addItem(entry)
            }
            item.submenu = sub
            menu.addItem(item)
        }
        if !properties.isEmpty {
            let item = NSMenuItem(title: "Text or document property", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for attribute in properties {
                let entry = NSMenuItem(title: attribute, action: #selector(addFromMenu(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = ComposerRow.Kind.property(attribute: attribute) as Any
                sub.addItem(entry)
            }
            item.submenu = sub
            menu.addItem(item)
        }
        addButton.menu = menu
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        if let kind = sender.representedObject as? ComposerRow.Kind { add(kind) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    private func colorIndex(of name: String) -> Int? { nodes.nodes.first { $0.name == name }?.index }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.rows.indices.contains(row), let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id) else { return nil }
        let line = model.rows[row]
        return centered(cell(for: column, line: line), stretch: column == .attribute)
    }

    /// `view` in a cell the height of the row, centred vertically (text fields would sit at the top).
    private func centered(_ view: NSView?, stretch: Bool) -> NSView? {
        guard let view else { return nil }
        let cell = NSTableCellView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        var constraints = [view.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
        if stretch {
            constraints += [view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                            view.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2)]
        } else if view is NSButton, !(view is NSPopUpButton) {
            constraints.append(view.centerXAnchor.constraint(equalTo: cell.centerXAnchor))
        } else {
            constraints += [view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                            view.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2)]
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    private func cell(for column: Column, line: ComposerRow) -> NSView? {
        switch column {
        case .node:
            let field = NSTextField(labelWithString: "")
            switch line.kind {
            case .node(let name, _):
                let color = colorIndex(of: name).map(NodeColors.color(at:)) ?? .secondaryLabelColor
                let text = NSMutableAttributedString(string: "\u{25CF} ", attributes: [.foregroundColor: color])
                text.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]))
                field.attributedStringValue = text
            case .property: field.stringValue = "Text/doc"; field.textColor = .secondaryLabelColor
            case .count: field.stringValue = "Hits"; field.textColor = .secondaryLabelColor
            }
            return field
        case .attribute:
            if line.isCount {
                let field = NSTextField(labelWithString: "number of hits")
                field.textColor = .secondaryLabelColor
                return field
            }
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.controlSize = .small
            let choices: [String]
            if case .property = line.kind { choices = properties } else { choices = positional }
            popUp.addItems(withTitles: choices)
            if let current = line.attribute { if popUp.indexOfItem(withTitle: current) < 0 { popUp.addItem(withTitle: current) }; popUp.selectItem(withTitle: current) }
            popUp.target = self
            popUp.action = #selector(attributeChanged(_:))
            return popUp
        case .ignoreCase:
            guard !line.isCount else { return nil }
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(ignoreCaseChanged(_:)))
            box.state = line.ignoreCase ? .on : .off
            box.setAccessibilityLabel("Ignore case")
            return box
        case .sort:
            let button = NSButton()
            button.isBordered = false
            let symbol: String, label: String
            switch line.sort {
            case .none: symbol = "arrow.up.arrow.down"; label = "Not in order. Click to order ascending."
            case .ascending: symbol = "arrow.up"; label = "Ascending. Click for descending."
            case .descending: symbol = "arrow.down"; label = "Descending. Click to clear."
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.contentTintColor = line.sort == .none ? .tertiaryLabelColor : .controlAccentColor
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = #selector(sortClicked(_:))
            return button
        case .remove:
            guard !line.isCount else { return nil }
            let button = NSButton()
            button.isBordered = false
            button.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "Remove"
            button.target = self
            button.action = #selector(removeClicked(_:))
            return button
        }
    }

    private func id(of sender: NSView) -> UUID? {
        let row = table.row(for: sender)
        return model.rows.indices.contains(row) ? model.rows[row].id : nil
    }

    @objc private func attributeChanged(_ sender: NSPopUpButton) {
        guard let id = id(of: sender), let title = sender.titleOfSelectedItem else { return }
        model.setAttribute(title, for: id)
        table.reloadData()
    }

    @objc private func ignoreCaseChanged(_ sender: NSButton) {
        guard let id = id(of: sender) else { return }
        model.setIgnoreCase(sender.state == .on, for: id)
    }

    @objc private func sortClicked(_ sender: NSButton) {
        guard let id = id(of: sender) else { return }
        model.cycleSort(for: id)
        table.reloadData()
    }

    @objc private func removeClicked(_ sender: NSButton) {
        guard let id = id(of: sender) else { return }
        model.remove(id)
        table.reloadData()
        updateRunButton()
    }

    // MARK: Reordering

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let source = info.draggingPasteboard.string(forType: Self.dragType).flatMap(Int.init) else { return false }
        model.move(from: source, toGap: row)
        table.reloadData()
        return true
    }

    // MARK: Buttons

    private func updateRunButton() { runButton.isEnabled = !model.isEmpty }

    private func show(error: Error) {
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
    }

    @objc func runTapped() {
        guard !model.isEmpty else {
            errorLabel.stringValue = FrequencyError.noFields.localizedDescription
            errorLabel.isHidden = false
            return
        }
        let minimum = max(Int(minFrequencyField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1, 1)
        onRun?(model.fields, model.sortKeys, minimum, nodes)
        close()
    }

    @objc private func cancelTapped() { close() }

    /// Closes the sheet (when it is one).
    private func close() { if presentingViewController != nil { dismiss(self) } }
}
