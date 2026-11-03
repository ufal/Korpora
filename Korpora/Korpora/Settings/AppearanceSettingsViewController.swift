import Cocoa

/// Concordance-table styling: the results font (via the standard Font
/// Panel, `Cmd-T`), per-script font overrides, and the colors used for
/// positional/structural attributes and row striping. General app chrome
/// (menus/buttons/labels) deliberately has no override here - it stays on
/// the system font/colors throughout, matching this project's "stick to
/// the Macintosh HIG" preference; only *content* fonts/colors are
/// user-customizable, the same way e.g. Mail lets you pick a message-list
/// font without touching its own chrome.
final class AppearanceSettingsViewController: NSViewController {
    private let fontLabel = NSTextField(labelWithString: "")
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

    /// Sorted for stable display - `AppSettings.scriptFontOverrides` is a
    /// plain `[String: String]` with no inherent order.
    private(set) var scriptOverrideRows: [(script: UnicodeScript, fontName: String)] = []
    /// The script the Font Panel is currently choosing a font for. Stays set while the panel is open,
    /// so every change made in it is applied (not just the first); follows the selected row.
    private(set) var pendingScript: UnicodeScript?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))

        let fontTitle = NSTextField(labelWithString: "Results font:")
        let selectFontButton = NSButton(title: "Select…", target: self, action: #selector(selectFont))
        updateFontLabel()

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

        let scriptTitle = NSTextField(labelWithString: "Per-script fonts:")
        scriptTitle.font = .boldSystemFont(ofSize: 12)
        let scriptHint = NSTextField(wrappingLabelWithString:
            "Gives text in a specific script its own font instead of the results font above - useful when "
                + "one font doesn't cover every script a corpus contains. Double-click a row to change its font.")
        scriptHint.font = .systemFont(ofSize: 11)
        scriptHint.textColor = .secondaryLabelColor

        let scriptColumn = NSTableColumn(identifier: .init("script"))
        scriptColumn.title = "Script"
        scriptColumn.width = 110
        scriptColumn.minWidth = 80
        let fontColumn = NSTableColumn(identifier: .init("font"))
        fontColumn.title = "Font"
        fontColumn.minWidth = 120
        scriptTableView.addTableColumn(scriptColumn)
        scriptTableView.addTableColumn(fontColumn)
        scriptTableView.headerView = NSTableHeaderView()
        scriptTableView.target = self
        scriptTableView.doubleAction = #selector(changeSelectedOverride)
        scriptTableView.dataSource = self
        scriptTableView.delegate = self
        scriptTableView.style = .plain
        scriptTableView.usesAlternatingRowBackgroundColors = true
        scriptScrollView.documentView = scriptTableView
        scriptScrollView.hasVerticalScroller = true
        scriptScrollView.borderType = .bezelBorder

        let addButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
            target: self, action: #selector(addOverrideTapped))
        let removeButton = removeScriptFontButton
        removeButton.target = self
        removeButton.action = #selector(removeSelectedOverride)
        removeButton.toolTip = "Stop using a special font for the selected script"
        addButton.toolTip = "Choose a script to give its own font"
        changeScriptFontButton.target = self
        changeScriptFontButton.action = #selector(changeSelectedOverride)
        changeScriptFontButton.toolTip = "Choose another font for the selected script (or double-click it)"
        changeScriptFontButton.isEnabled = false
        removeButton.isEnabled = false

        let views: [NSView] = [
            fontTitle, fontLabel, selectFontButton,
            colorsTitle, positionalLabel, positionalColorWell, structuralLabel, structuralColorWell,
            alternatingRowCheckbox,
            scriptTitle, scriptHint, scriptScrollView, addButton, removeButton, changeScriptFontButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        NSLayoutConstraint.activate([
            fontTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            fontTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            fontLabel.centerYAnchor.constraint(equalTo: fontTitle.centerYAnchor),
            fontLabel.leadingAnchor.constraint(equalTo: fontTitle.trailingAnchor, constant: 8),
            selectFontButton.topAnchor.constraint(equalTo: fontTitle.bottomAnchor, constant: 8),
            selectFontButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            colorsTitle.topAnchor.constraint(equalTo: selectFontButton.bottomAnchor, constant: 20),
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

            scriptTitle.topAnchor.constraint(equalTo: alternatingRowCheckbox.bottomAnchor, constant: 20),
            scriptTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            scriptHint.topAnchor.constraint(equalTo: scriptTitle.bottomAnchor, constant: 4),
            scriptHint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scriptHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scriptScrollView.topAnchor.constraint(equalTo: scriptHint.bottomAnchor, constant: 8),
            scriptScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scriptScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            // At least 80 tall; takes the spare height when the window is resized.
            scriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            addButton.topAnchor.constraint(equalTo: scriptScrollView.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: scriptScrollView.leadingAnchor),
            removeButton.topAnchor.constraint(equalTo: scriptScrollView.bottomAnchor, constant: 6),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 2),
            removeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            changeScriptFontButton.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
            changeScriptFontButton.trailingAnchor.constraint(equalTo: scriptScrollView.trailingAnchor),
        ])

        // A centered column; the per-script list in it takes extra height.
        view = SettingsLayout.centeredRoot(around: root, width: 420)
        preferredContentSize = NSSize(width: 420, height: 400)
        reloadScriptOverrides()
    }

    private func updateFontLabel() {
        let settings = AppSettings.shared
        fontLabel.stringValue = "\(settings.resultsFontName) \(Int(settings.resultsFontSize))pt"
    }

    @objc private func selectFont() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(AppSettings.shared.resultsFont, isMultiple: false)
        NSFontPanel.shared.orderFront(self)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let newFont = sender.convert(AppSettings.shared.resultsFont)
        AppSettings.shared.resultsFontName = newFont.fontName
        AppSettings.shared.resultsFontSize = Double(newFont.pointSize)
        updateFontLabel()
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

    private func reloadScriptOverrides() {
        let selected = selectedScript
        let overrides = settings.scriptFontOverrides
        scriptOverrideRows = overrides.compactMap { key, fontName in
            UnicodeScript(rawValue: key).map { (script: $0, fontName: fontName) }
        }.sorted { $0.script.displayName < $1.script.displayName }
        scriptTableView.reloadData()
        if let selected, let row = scriptOverrideRows.firstIndex(where: { $0.script == selected }) {
            scriptTableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateScriptButtons()
    }

    private var selectedScript: UnicodeScript? {
        scriptOverrideRows.indices.contains(scriptTableView.selectedRow)
            ? scriptOverrideRows[scriptTableView.selectedRow].script : nil
    }

    private func updateScriptButtons() {
        let hasSelection = selectedScript != nil
        changeScriptFontButton.isEnabled = hasSelection
        removeScriptFontButton.isEnabled = hasSelection
    }

    /// The font an override currently has (the results font if there is none yet).
    private func font(for script: UnicodeScript) -> NSFont {
        settings.scriptFontOverrides[script.rawValue]
            .flatMap { NSFont(name: $0, size: CGFloat(settings.resultsFontSize)) } ?? settings.resultsFont
    }

    /// A pull-down of scripts not yet overridden: choosing one opens the Font Panel for it. (A script
    /// that already has a font is changed with "Change Font\u{2026}" or by double-clicking it.)
    @objc private func addOverrideTapped(_ sender: NSButton) {
        let existing = Set(settings.scriptFontOverrides.keys)
        let menu = NSMenu()
        for script in UnicodeScript.allCases where script != .other && !existing.contains(script.rawValue) {
            let item = NSMenuItem(title: script.displayName, action: #selector(scriptPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = script
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func scriptPicked(_ sender: NSMenuItem) {
        guard let script = sender.representedObject as? UnicodeScript else { return }
        // A new override starts as the results font, so choosing in the panel changes it from there.
        var overrides = settings.scriptFontOverrides
        overrides[script.rawValue] = settings.resultsFontName
        settings.scriptFontOverrides = overrides
        reloadScriptOverrides()
        if let row = scriptOverrideRows.firstIndex(where: { $0.script == script }) {
            scriptTableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        beginChoosingFont(for: script)
    }

    @objc private func changeSelectedOverride() {
        guard let script = selectedScript else { return }
        beginChoosingFont(for: script)
    }

    /// Points the Font Panel at `script`'s font; every change made in it is applied to that script.
    private func beginChoosingFont(for script: UnicodeScript) {
        pendingScript = script
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(scriptFontChanged(_:))
        manager.setSelectedFont(font(for: script), isMultiple: false)
        NSFontPanel.shared.orderFront(self)
    }

    @objc func scriptFontChanged(_ sender: NSFontManager?) {
        guard let sender, let script = pendingScript else { return }
        applyFont(sender.convert(font(for: script)), to: script)
    }

    /// Stores `font` as the font for `script`.
    func applyFont(_ font: NSFont, to script: UnicodeScript) {
        var overrides = settings.scriptFontOverrides
        overrides[script.rawValue] = font.fontName
        settings.scriptFontOverrides = overrides
        reloadScriptOverrides()
    }

    @objc private func removeSelectedOverride() {
        guard let script = selectedScript else { return }
        var overrides = settings.scriptFontOverrides
        overrides.removeValue(forKey: script.rawValue)
        settings.scriptFontOverrides = overrides
        if pendingScript == script { pendingScript = nil }
        reloadScriptOverrides()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Leaving the pane: the Font Panel no longer belongs to a script.
        pendingScript = nil
    }
}

extension AppearanceSettingsViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { scriptOverrideRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let override = scriptOverrideRows[row]
        if tableColumn?.identifier.rawValue == "script" {
            let field = NSTextField(labelWithString: override.script.displayName)
            field.font = .systemFont(ofSize: 12)
            return field
        }
        // The font's name, set in that font.
        let field = NSTextField(labelWithString: override.fontName)
        field.font = NSFont(name: override.fontName, size: 12) ?? .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateScriptButtons()
        // With the Font Panel open for a script, selecting another row moves it to that row's script.
        if pendingScript != nil, let script = selectedScript {
            beginChoosingFont(for: script)
        }
    }
}
