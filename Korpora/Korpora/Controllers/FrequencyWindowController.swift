import Cocoa
import KorporaEngine

/// A disposable results window for `ConcordanceDocument.frequencyTable(_:minFrequency:)`
/// (docs/frequency-composer.md): a column for each field, with the node's colour on its heading, then the count.
/// Any heading can be clicked to sort (the order of the headings clicked is the priority), and the table says how
/// many of the hits its rows cover.
final class FrequencyWindowController: NSWindowController {
    convenience init(table: FrequencyTable, sortKeys: [FrequencySortKey], minFrequency: Int = 1,
                     nodes: QueryNodes = QueryNodes(""), context: [String] = []) {
        let names = table.fields.map { field in
            field.node.map { "\($0).\(field.attribute)" } ?? field.attribute
        }
        var lines = context
        lines.append("Frequencies of \(names.joined(separator: ", "))"
            + (table.fields.contains { $0.ignoreCase } ? ", ignoring case" : "")
            + (minFrequency > 1 ? ", frequency at least \(minFrequency)" : ""))
        let viewController = FrequencyViewController(table: table, sortKeys: sortKeys, nodes: nodes, context: lines)
        let window = NSWindow(contentViewController: viewController)
        let width = CGFloat(max(1, table.fields.count)) * 150 + 280
        window.setContentSize(NSSize(width: min(width, 900), height: 420))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Frequencies: \(names.joined(separator: ", "))"
        self.init(window: window)
    }
}

final class FrequencyViewController: NSViewController {
    private enum Fixed: String { case count, percent, perMillion }

    private var source: FrequencyTable
    private var shown: FrequencyTable
    private let nodes: QueryNodes
    private let context: [String]
    let tableView = SortableTableView()
    private let scrollView = NSScrollView()
    let footer = NSTextField(labelWithString: "")
    private(set) var container: TableChartContainerView!
    private var initialKeys: [FrequencySortKey]
    private var sortGeneration = 0
    private var applyingDescriptors = false

    init(table: FrequencyTable, sortKeys: [FrequencySortKey], nodes: QueryNodes, context: [String]) {
        self.source = table
        self.shown = table
        self.nodes = nodes
        self.context = context
        self.initialKeys = sortKeys
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The rows now on show (tests read them).
    var displayedTable: FrequencyTable { shown }

    override func loadView() {
        container = TableChartContainerView(table: scrollView)
        func label(_ row: FrequencyRow) -> String { row.values.joined(separator: " \u{00B7} ") }
        var measures: [TableChartContainerView.Measure] = [
            .init(title: "Frequency") { [weak self] in
                (self?.shown.rows ?? []).map { BarChartView.Bar(label: label($0), value: Double($0.count)) }
            },
        ]
        if source.rows.contains(where: { $0.perMillion != nil }) {
            measures.append(.init(title: "Per million") { [weak self] in
                (self?.shown.rows ?? []).compactMap { row in row.perMillion.map { BarChartView.Bar(label: label(row), value: $0) } }
            })
        }
        container.setMeasures(measures)

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: container.bottomAnchor, constant: 4),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
    }

    /// File > Print… (see `WindowPrinting`): the chart or the table, whichever shows.
    @objc func printWindowContents(_ sender: Any?) {
        WindowPrinting.run(container.printableView, jobTitle: view.window?.title ?? "Frequencies",
                           header: container.printHeader(context), in: view.window)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self

        for (index, field) in source.fields.enumerated() {
            let column = NSTableColumn(identifier: .init("field\(index)"))
            column.width = 150
            column.minWidth = 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: "field\(index)", ascending: true)
            let name = field.node.map { "\($0) \(field.attribute)" } ?? field.attribute
            column.title = name
            let heading = NSMutableAttributedString()
            if let node = field.node, let at = nodes.nodes.first(where: { $0.name == node })?.index {
                heading.append(NSAttributedString(string: "\u{25CF} ", attributes: [.foregroundColor: NodeColors.color(at: at)]))
            }
            heading.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]))
            column.headerCell.attributedStringValue = heading
            tableView.addTableColumn(column)
        }
        let count = NSTableColumn(identifier: .init(Fixed.count.rawValue))
        count.title = "Freq"
        count.width = 90
        count.sortDescriptorPrototype = NSSortDescriptor(key: Fixed.count.rawValue, ascending: false)
        tableView.addTableColumn(count)

        let percent = NSTableColumn(identifier: .init(Fixed.percent.rawValue))
        percent.title = "%"
        percent.width = 70
        percent.sortDescriptorPrototype = NSSortDescriptor(key: Fixed.percent.rawValue, ascending: false)
        tableView.addTableColumn(percent)

        // Relative to the whole corpus, or for a document property to that value's documents.
        if source.rows.contains(where: { $0.perMillion != nil }) {
            let norm = NSTableColumn(identifier: .init(Fixed.perMillion.rawValue))
            norm.title = "Per million"
            norm.width = 100
            norm.headerToolTip = "Instances per million tokens (of the corpus, or of the documents with this value)"
            norm.sortDescriptorPrototype = NSSortDescriptor(key: Fixed.perMillion.rawValue, ascending: false)
            tableView.addTableColumn(norm)
        }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        tableView.onSortDescriptorsChange = { [weak self] descriptors in
            guard let self, !applyingDescriptors else { return }
            sort(by: Self.keys(from: descriptors))
        }
        applyingDescriptors = true
        tableView.sortDescriptors = initialKeys.isEmpty
            ? [NSSortDescriptor(key: Fixed.count.rawValue, ascending: false)]
            : initialKeys.map(Self.descriptor(for:))
        applyingDescriptors = false
        sort(by: initialKeys)
    }

    // MARK: Sorting

    static func descriptor(for key: FrequencySortKey) -> NSSortDescriptor {
        let name: String
        switch key.column {
        case .field(let index): name = "field\(index)"
        case .count: name = Fixed.count.rawValue
        case .percent: name = Fixed.percent.rawValue
        case .perMillion: name = Fixed.perMillion.rawValue
        }
        return NSSortDescriptor(key: name, ascending: key.ascending)
    }

    static func keys(from descriptors: [NSSortDescriptor]) -> [FrequencySortKey] {
        descriptors.compactMap { descriptor in
            guard let key = descriptor.key else { return nil }
            if key.hasPrefix("field"), let index = Int(key.dropFirst(5)) { return FrequencySortKey(.field(index), ascending: descriptor.ascending) }
            switch Fixed(rawValue: key) {
            case .count: return FrequencySortKey(.count, ascending: descriptor.ascending)
            case .percent: return FrequencySortKey(.percent, ascending: descriptor.ascending)
            case .perMillion: return FrequencySortKey(.perMillion, ascending: descriptor.ascending)
            case nil: return nil
            }
        }
    }

    /// Sorts off the main thread (100,000 rows of text take about a second) and shows the result when it is the
    /// latest one asked for.
    private func sort(by keys: [FrequencySortKey]) {
        sortGeneration += 1
        let generation = sortGeneration
        let table = source
        // A small table is sorted at once; a big one in the background, so the window doesn't freeze.
        if table.rows.count <= 5_000 {
            shown = table.sorted(by: keys)
            tableView.reloadData()
            container.refreshChart()
            updateFooter()
            return
        }
        Task { @MainActor [weak self] in
            let sorted = await Task.detached { table.sorted(by: keys) }.value
            guard let self, generation == self.sortGeneration else { return }
            self.shown = sorted
            self.tableView.reloadData()
            self.container.refreshChart()
            self.updateFooter()
        }
    }

    private func updateFooter() {
        let rows = shown.rows.count.formatted(), hits = shown.totalMatches.formatted()
        if shown.shownMatches < shown.totalMatches {
            footer.stringValue = "\(rows) combinations, covering \(shown.shownMatches.formatted()) of \(hits) hits"
                + (shown.isCut ? " (the rest have the lowest counts and are left out)." : " (the rest are below the minimum frequency).")
        } else {
            footer.stringValue = "\(rows) combinations, \(hits) hits."
        }
    }
}

extension FrequencyViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shown.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let item = shown.rows[row]
        let text: String
        if id.hasPrefix("field"), let index = Int(id.dropFirst(5)) {
            text = item.values.indices.contains(index) ? item.values[index] : ""
        } else {
            switch Fixed(rawValue: id) {
            case .count: text = item.count.formatted()
            case .percent: text = item.percent.formatted(.number.precision(.fractionLength(2)))
            // Blank, not "0", when the engine gave none: "0" would read as a measured value.
            case .perMillion: text = item.perMillion.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? ""
            case nil: return nil
            }
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}
