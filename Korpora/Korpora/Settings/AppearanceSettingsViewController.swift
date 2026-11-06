import Cocoa

/// Concordance-table styling: a font and a size for each script (docs/typography.md), chosen with the standard
/// Font Panel, and the colors used for positional/structural attributes and row striping. General app chrome
/// (menus/buttons/labels) deliberately has no override here - it stays on the system font/colors throughout,
/// matching this project's "stick to the Macintosh HIG" preference; only *content* fonts/colors are
/// user-customizable, the same way e.g. Mail lets you pick a message-list font without touching its own chrome.
final class AppearanceSettingsViewController: NSViewController {
    private let positionalColorWell = NSColorWell()
    private let structuralColorWell = NSColorWell()
    private let alternatingRowCheckbox = NSButton(
        checkboxWithTitle: "Alternate row background", target: nil, action: nil)
    let scriptTableView = NSTableView()
    private let scriptScrollView = NSScrollView()
    let changeScriptFontButton = NSButton(title: "Change Font\u{2026}", target: nil, action: nil)
    let removeScriptFontButton = NSButton(
        image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: nil, action: nil)
    /// The settings the per-script list reads and writes (the app's own; tests pass their own).
    var settings: AppSettings = .shared

    /// The rows of the table: Latin first, then the scripts that have a font of their own, then "All other
    /// scripts", which is always there (without an entry it is the system's font for the script).
    private(set) var scriptRows: [ScriptRow] = []
    /// The row the Font Panel is currently choosing a font for. Stays set while the panel is open, so every
    /// change made in it is applied (not just the first); follows the selected row.
    private(set) var pendingKey: String?

    struct ScriptRow: Equatable {
        /// A Unicode script name, `CJK`, or `Other`.
        var key: String
        var font: ScriptFont?
        var title: String {
            switch key {
            case ScriptFonts.otherKey: return "All other scripts"
            case UnicodeScript.cjkGroup.name: return "CJK (Han, kana, Hangul)"
            default: return key.replacingOccurrences(of: "_", with: " ")
            }
        }
        var isRemovable: Bool { key != UnicodeScript.latin.name }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))

        let scriptTitle = NSTextField(labelWithString: "Fonts by script:")
        scriptTitle.font = .boldSystemFont(ofSize: 12)
        let scriptHint = NSTextField(wrappingLabelWithString:
            "Each script has its own font and size, so Chinese can be larger than Latin. A script without a row "
                + "uses \u{201C}All other scripts\u{201D}, which is the system\u{2019}s font for it. Double-click a font to change it, "
                + "or a size to type one.")
        scriptHint.font = .systemFont(ofSize: 11)
        scriptHint.textColor = .secondaryLabelColor

        let scriptColumn = NSTableColumn(identifier: .init("script"))
        scriptColumn.title = "Script"
        scriptColumn.width = 165
        scriptColumn.minWidth = 120
        let fontColumn = NSTableColumn(identifier: .init("font"))
        fontColumn.title = "Font"
        fontColumn.minWidth = 120
        let sizeColumn = NSTableColumn(identifier: .init("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 50
        sizeColumn.minWidth = 40
        sizeColumn.maxWidth = 70
        for column in [scriptColumn, fontColumn, sizeColumn] { scriptTableView.addTableColumn(column) }
        scriptTableView.headerView = NSTableHeaderView()
        scriptTableView.target = self
        scriptTableView.doubleAction = #selector(changeSelectedFont)
        scriptTableView.dataSource = self
        scriptTableView.delegate = self
        scriptTableView.style = .plain
        scriptTableView.usesAlternatingRowBackgroundColors = true
        scriptScrollView.documentView = scriptTableView
        scriptScrollView.hasVerticalScroller = true
        scriptScrollView.borderType = .bezelBorder

        let addButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
            target: self, action: #selector(addScriptTapped))
        let removeButton = removeScriptFontButton
        removeButton.target = self
        removeButton.action = #selector(removeSelectedRow)
        removeButton.toolTip = "Stop using a font of its own for the selected script"
        addButton.toolTip = "Give another script a font and a size of its own"
        changeScriptFontButton.target = self
        changeScriptFontButton.action = #selector(changeSelectedFont)
        changeScriptFontButton.toolTip = "Choose another font for the selected script (or double-click it)"
        changeScriptFontButton.isEnabled = false
        removeButton.isEnabled = false

        let colorsTitle = NSTextField(labelWithString: "Colors:")
        colorsTitle.font = .boldSystemFont(ofSize: 12)
        let positionalLabel = NSTextField(labelWithString: "Positional attributes:")
        let structuralLabel = NSTextField(labelWithString: "Structural attribute:")
        positionalColorWell.color = AppSettings.shared.positionalAttributeColor
        positionalColorWell.target = self
        positionalColorWell.action = #selector(positionalColorChanged)
        structuralColorWell.color = AppSettings.shared.structuralAttributeColor
        structuralColorWell.target = self
        structuralColorWell.action = #selector(structuralColorChanged)

        alternatingRowCheckbox.state = AppSettings.shared.usesAlternatingRowBackground ? .on : .off
        alternatingRowCheckbox.target = self
        alternatingRowCheckbox.action = #selector(alternatingRowChanged)

        let views: [NSView] = [
            scriptTitle, scriptHint, scriptScrollView, addButton, removeButton, changeScriptFontButton,
            colorsTitle, positionalLabel, positionalColorWell, structuralLabel, structuralColorWell,
            alternatingRowCheckbox,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        NSLayoutConstraint.activate([
            scriptTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            scriptTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            scriptHint.topAnchor.constraint(equalTo: scriptTitle.bottomAnchor, constant: 4),
            scriptHint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scriptHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scriptScrollView.topAnchor.constraint(equalTo: scriptHint.bottomAnchor, constant: 8),
            scriptScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scriptScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            // Room for the header and five rows; takes the spare height when the window is resized.
            scriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),

            addButton.topAnchor.constraint(equalTo: scriptScrollView.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: scriptScrollView.leadingAnchor),
            removeButton.topAnchor.constraint(equalTo: scriptScrollView.bottomAnchor, constant: 6),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 2),
            changeScriptFontButton.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
            changeScriptFontButton.trailingAnchor.constraint(equalTo: scriptScrollView.trailingAnchor),

            colorsTitle.topAnchor.constraint(equalTo: removeButton.bottomAnchor, constant: 20),
            colorsTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            positionalLabel.topAnchor.constraint(equalTo: colorsTitle.bottomAnchor, constant: 10),
            positionalLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            positionalColorWell.centerYAnchor.constraint(equalTo: positionalLabel.centerYAnchor),
            positionalColorWell.leadingAnchor.constraint(equalTo: positionalLabel.trailingAnchor, constant: 8),
            positionalColorWell.widthAnchor.constraint(equalToConstant: 44),

            structuralLabel.topAnchor.constraint(equalTo: positionalLabel.bottomAnchor, constant: 8),
            structuralLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            structuralColorWell.centerYAnchor.constraint(equalTo: structuralLabel.centerYAnchor),
            structuralColorWell.leadingAnchor.constraint(equalTo: structuralLabel.trailingAnchor, constant: 8),
            structuralColorWell.widthAnchor.constraint(equalToConstant: 44),

            alternatingRowCheckbox.topAnchor.constraint(equalTo: structuralLabel.bottomAnchor, constant: 12),
            alternatingRowCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            alternatingRowCheckbox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        // A centered column; the per-script list in it takes extra height.
        view = SettingsLayout.centeredRoot(around: root, width: 460)
        preferredContentSize = NSSize(width: 460, height: 520)
        reloadRows()
    }

    @objc private func positionalColorChanged() {
        AppSettings.shared.positionalAttributeColor = positionalColorWell.color
    }

    @objc private func structuralColorChanged() {
        AppSettings.shared.structuralAttributeColor = structuralColorWell.color
    }

    @objc private func alternatingRowChanged() {
        AppSettings.shared.usesAlternatingRowBackground = alternatingRowCheckbox.state == .on
    }

    // MARK: The table

    private func reloadRows() {
        let selected = selectedKey
        let table = settings.scriptFonts
        let middle = table.keys.filter { $0 != UnicodeScript.latin.name && $0 != ScriptFonts.otherKey }.sorted {
            ScriptRow(key: $0).title < ScriptRow(key: $1).title
        }
        scriptRows = ([UnicodeScript.latin.name] + middle + [ScriptFonts.otherKey]).map {
            ScriptRow(key: $0, font: table[$0] ?? ($0 == UnicodeScript.latin.name ? ScriptFonts.defaultLatin : nil))
        }
        scriptTableView.reloadData()
        if let selected, let row = scriptRows.firstIndex(where: { $0.key == selected }) {
            scriptTableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selectedKey: String? {
        scriptRows.indices.contains(scriptTableView.selectedRow) ? scriptRows[scriptTableView.selectedRow].key : nil
    }

    private func updateButtons() {
        let selected = scriptRows.indices.contains(scriptTableView.selectedRow) ? scriptRows[scriptTableView.selectedRow] : nil
        changeScriptFontButton.isEnabled = selected != nil
        // Latin can't go (it is the default); "All other scripts" goes back to the system font when it has an entry.
        removeScriptFontButton.isEnabled = selected.map { $0.isRemovable && settings.scriptFonts[$0.key] != nil } ?? false
    }

    /// The font a row currently shows: its own, or for "All other scripts" without one, the Latin size.
    private func currentFont(forKey key: String) -> NSFont {
        let table = settings.scriptFonts
        let entry = table[key] ?? ScriptFonts.latin(in: table)
        let size = table[key]?.size ?? ScriptFonts.latin(in: table).size
        return NSFont(name: entry.name, size: CGFloat(size)) ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    /// A pull-down of scripts that have no row yet; choosing one adds a row (a copy of the Latin font) and
    /// opens the Font Panel for it. Common scripts first, every other script Unicode names under "More scripts".
    @objc private func addScriptTapped(_ sender: NSButton) {
        let existing = Set(settings.scriptFonts.keys)
        func item(_ key: String, _ title: String) -> NSMenuItem? {
            guard !existing.contains(key) else { return nil }
            let item = NSMenuItem(title: title, action: #selector(scriptPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            return item
        }
        let menu = NSMenu()
        for entry in [(UnicodeScript.cjkGroup.name, "CJK (Han, kana, Hangul)")] { item(entry.0, entry.1).map(menu.addItem) }
        menu.addItem(.separator())
        let common = ["Arabic", "Armenian", "Bengali", "Cyrillic", "Devanagari", "Georgian", "Greek", "Gujarati", "Hebrew",
                      "Tamil", "Thai"]
        for name in common { item(name, name).map(menu.addItem) }
        let more = NSMenu(title: "More scripts")
        for script in UnicodeScript.all where !common.contains(script.name) && script != .latin {
            item(script.name, script.displayName).map(more.addItem)
        }
        let moreItem = NSMenuItem(title: "More scripts", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        menu.addItem(moreItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func scriptPicked(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        // A new row starts as the Latin font and size, so choosing in the panel changes it from there.
        var table = settings.scriptFonts
        table[key] = ScriptFonts.latin(in: table)
        settings.scriptFonts = table
        reloadRows()
        if let row = scriptRows.firstIndex(where: { $0.key == key }) {
            scriptTableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        beginChoosingFont(forKey: key)
    }

    @objc private func changeSelectedFont() {
        guard let key = selectedKey else { return }
        beginChoosingFont(forKey: key)
    }

    /// Points the Font Panel at `key`'s font; every change made in it is applied to that row.
    private func beginChoosingFont(forKey key: String) {
        pendingKey = key
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(scriptFontChanged(_:))
        manager.setSelectedFont(currentFont(forKey: key), isMultiple: false)
        NSFontPanel.shared.orderFront(self)
    }

    @objc func scriptFontChanged(_ sender: NSFontManager?) {
        guard let sender, let key = pendingKey else { return }
        apply(sender.convert(currentFont(forKey: key)), forKey: key)
    }

    /// Stores `font`, name and size, for the row `key`.
    func apply(_ font: NSFont, forKey key: String) {
        var table = settings.scriptFonts
        table[key] = ScriptFont(name: font.fontName, size: Double(font.pointSize))
        settings.scriptFonts = table
        reloadRows()
    }

    /// Stores a size typed in the table.
    func applySize(_ size: Double, forKey key: String) {
        var table = settings.scriptFonts
        let clamped = min(max(size, ScriptFonts.minimumSize), ScriptFonts.maximumSize)
        let entry = table[key] ?? ScriptFonts.latin(in: table)
        table[key] = ScriptFont(name: entry.name, size: clamped)
        settings.scriptFonts = table
        reloadRows()
    }

    @objc private func removeSelectedRow() {
        guard let key = selectedKey, key != UnicodeScript.latin.name else { return }
        var table = settings.scriptFonts
        table.removeValue(forKey: key)
        settings.scriptFonts = table
        if pendingKey == key { pendingKey = nil }
        reloadRows()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Leaving the pane: the Font Panel no longer belongs to a row.
        pendingKey = nil
    }
}

extension AppearanceSettingsViewController: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { scriptRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let scriptRow = scriptRows[row]
        let field: NSTextField
        switch tableColumn?.identifier.rawValue {
        case "script":
            field = NSTextField(labelWithString: scriptRow.title)
            field.font = .systemFont(ofSize: 12)
        case "size":
            let size = scriptRow.font?.size ?? ScriptFonts.latin(in: settings.scriptFonts).size
            field = NSTextField(string: size == size.rounded() ? String(Int(size)) : String(size))
            field.isEditable = true
            field.isBordered = false
            field.drawsBackground = false
            field.alignment = .right
            field.font = .systemFont(ofSize: 12)
            field.delegate = self
            field.tag = row
            field.textColor = scriptRow.font == nil ? .secondaryLabelColor : .labelColor
        default:
            // The font's name, set in that font; "All other scripts" without an entry says what it is.
            if let font = scriptRow.font {
                field = NSTextField(labelWithString: font.name)
                field.font = NSFont(name: font.name, size: 12) ?? .systemFont(ofSize: 12)
            } else {
                field = NSTextField(labelWithString: "System font for the script")
                field.font = .systemFont(ofSize: 12)
                field.textColor = .secondaryLabelColor
            }
            field.lineBreakMode = .byTruncatingTail
        }
        // Centred in the row, so fonts with different metrics line up.
        let cell = NSView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        // With the Font Panel open for a row, selecting another row moves it to that row's script.
        if pendingKey != nil, let key = selectedKey {
            beginChoosingFont(forKey: key)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, scriptRows.indices.contains(field.tag) else { return }
        let key = scriptRows[field.tag].key
        if let size = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) {
            applySize(size, forKey: key)
        } else {
            reloadRows()
        }
    }
}
