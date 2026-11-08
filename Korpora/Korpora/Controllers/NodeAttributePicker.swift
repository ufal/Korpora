import Cocoa

/// The popover that opens when a node is clicked: the corpus's token attributes, each with the value the node has in
/// the hit shown above (docs/frequency-composer.md). A click on one picks it.
final class NodeAttributePicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Entry: Equatable {
        var name: String
        /// The node's value in the hit on show; nil when there is none to show.
        var sample: String?
    }

    private let heading: String
    private let color: NSColor
    private let entries: [Entry]
    private let onPick: (String) -> Void
    private let table = NSTableView()

    init(heading: String, color: NSColor, entries: [Entry], onPick: @escaping (String) -> Void) {
        self.heading = heading
        self.color = color
        self.entries = entries
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let title = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(string: "\u{25CF} ", attributes: [.foregroundColor: color])
        text.append(NSAttributedString(string: heading, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        title.attributedStringValue = text
        let hint = NSTextField(labelWithString: "Count which attribute?")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let name = NSTableColumn(identifier: .init("name"))
        name.width = 110
        let value = NSTableColumn(identifier: .init("value"))
        value.width = 160
        table.addTableColumn(name)
        table.addTableColumn(value)
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(picked)
        table.setAccessibilityLabel("Attributes of \(heading)")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let rows = min(CGFloat(max(entries.count, 1)), 12)
        let height = rows * (table.rowHeight + 2) + 4

        let stack = NSStackView(views: [title, hint, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        view = stack
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let isName = tableColumn?.identifier.rawValue == "name"
        let field = NSTextField(labelWithString: isName ? entry.name : (entry.sample ?? ""))
        field.font = isName ? .systemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 12)
        field.textColor = isName ? .labelColor : .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    @objc private func picked() {
        let row = table.clickedRow
        guard entries.indices.contains(row) else { return }
        onPick(entries[row].name)
    }
}
