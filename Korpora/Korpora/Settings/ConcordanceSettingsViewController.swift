import Cocoa
import KorporaEngine

/// Global defaults for **brand-new** concordance documents - not
/// per-document overrides, which stay on the concordance window's own
/// toolbar popovers (Context). Changing a value
/// here never affects an already-open window, only the next one created.
final class ConcordanceSettingsViewController: NSViewController {
    private let leftContextField = NSTextField(string: "")
    private let rightContextField = NSTextField(string: "")
    private let viewModeControl = NSSegmentedControl(
        labels: ["KWIC", "Sentence"], trackingMode: .selectOne, target: nil, action: nil)
    private let maxLinesField = NSTextField(string: "")
    private let extendedContextField = NSTextField(string: "")
    // "Window", not "Sheet": the `.sheet` case keeps its name/rawValue for
    // UserDefaults backward compatibility, but it has presented a plain
    // non-modal window since 6.6's follow-up work (see
    // `ExtendedContextDisplayMode`) - the old label was simply wrong.
    private let extendedContextDisplayControl = NSSegmentedControl(
        labels: ["Window", "Inline"], trackingMode: .selectOne, target: nil, action: nil)
    private let allowMultipleExtendedContextsButton = NSButton(
        checkboxWithTitle: "Allow several at once (adds a disclosure triangle per line)",
        target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 250))

        let contextLabel = NSTextField(labelWithString: "Default context width:")
        let leftLabel = NSTextField(labelWithString: "Left:")
        let rightLabel = NSTextField(labelWithString: "Right:")
        let viewModeLabel = NSTextField(labelWithString: "Default view:")
        let maxLinesLabel = NSTextField(labelWithString: "Full sorting options up to (hits):")
        let extendedLabel = NSTextField(labelWithString: "Extended context tokens:")
        let extendedDisplayLabel = NSTextField(labelWithString: "Extended context display:")

        leftContextField.delegate = self
        rightContextField.delegate = self
        extendedContextField.delegate = self
        maxLinesField.delegate = self
        maxLinesField.toolTip = "Searches show every hit, however many. A result up to this size is sorted, shuffled and "
            + "grouped in memory with every option (several sort keys, retrograde, unique, alphabetical order of the "
            + "language, line groups). pando sorts one key, shuffles and samples a bigger result itself, in code-point "
            + "order; several keys, retrograde, unique and line groups then work on the first hits only."
        viewModeControl.segmentStyle = .texturedRounded
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.setToolTip("KWIC: the same number of tokens left and right of every hit.", forSegment: 0)
        viewModeControl.setToolTip("Sentence: the whole sentence around every hit.", forSegment: 1)
        extendedContextDisplayControl.segmentStyle = .texturedRounded
        extendedContextDisplayControl.target = self
        extendedContextDisplayControl.action = #selector(extendedContextDisplayModeChanged)
        allowMultipleExtendedContextsButton.target = self
        allowMultipleExtendedContextsButton.action = #selector(allowMultipleExtendedContextsChanged)

        let settings = AppSettings.shared
        leftContextField.stringValue = String(settings.defaultLeftContext)
        rightContextField.stringValue = String(settings.defaultRightContext)
        extendedContextField.stringValue = String(settings.defaultExtendedContextTokens)
        maxLinesField.stringValue = settings.maxConcordanceLines.formatted()
        viewModeControl.selectedSegment = settings.defaultViewMode == .sentence ? 1 : 0
        extendedContextDisplayControl.selectedSegment = settings.extendedContextDisplayMode == .inline ? 1 : 0
        allowMultipleExtendedContextsButton.state = settings.allowMultipleExtendedContexts ? .on : .off

        let views: [NSView] = [
            contextLabel, leftLabel, leftContextField, rightLabel, rightContextField,
            viewModeLabel, viewModeControl, maxLinesLabel, maxLinesField, extendedLabel, extendedContextField,
            extendedDisplayLabel, extendedContextDisplayControl,
            allowMultipleExtendedContextsButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        leftContextField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        rightContextField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        extendedContextField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        maxLinesField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        NSLayoutConstraint.activate([
            contextLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            contextLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            leftLabel.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 10),
            leftLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            leftContextField.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            leftContextField.leadingAnchor.constraint(equalTo: leftLabel.trailingAnchor, constant: 8),
            rightLabel.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            rightLabel.leadingAnchor.constraint(equalTo: leftContextField.trailingAnchor, constant: 16),
            rightContextField.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            rightContextField.leadingAnchor.constraint(equalTo: rightLabel.trailingAnchor, constant: 8),

            viewModeLabel.topAnchor.constraint(equalTo: leftLabel.bottomAnchor, constant: 20),
            viewModeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            viewModeControl.centerYAnchor.constraint(equalTo: viewModeLabel.centerYAnchor),
            viewModeControl.leadingAnchor.constraint(equalTo: viewModeLabel.trailingAnchor, constant: 8),

            maxLinesLabel.topAnchor.constraint(equalTo: viewModeLabel.bottomAnchor, constant: 20),
            maxLinesLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            maxLinesField.centerYAnchor.constraint(equalTo: maxLinesLabel.centerYAnchor),
            maxLinesField.leadingAnchor.constraint(equalTo: maxLinesLabel.trailingAnchor, constant: 8),

            extendedLabel.topAnchor.constraint(equalTo: maxLinesLabel.bottomAnchor, constant: 20),
            extendedLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            extendedContextField.centerYAnchor.constraint(equalTo: extendedLabel.centerYAnchor),
            extendedContextField.leadingAnchor.constraint(equalTo: extendedLabel.trailingAnchor, constant: 8),

            extendedDisplayLabel.topAnchor.constraint(equalTo: extendedLabel.bottomAnchor, constant: 12),
            extendedDisplayLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            extendedContextDisplayControl.centerYAnchor.constraint(equalTo: extendedDisplayLabel.centerYAnchor),
            extendedContextDisplayControl.leadingAnchor.constraint(equalTo: extendedDisplayLabel.trailingAnchor, constant: 8),

            // Indented under the display control, since it qualifies that
            // setting rather than standing on its own - it applies to both
            // Window and Inline.
            allowMultipleExtendedContextsButton.topAnchor.constraint(
                equalTo: extendedContextDisplayControl.bottomAnchor, constant: 10),
            allowMultipleExtendedContextsButton.leadingAnchor.constraint(
                equalTo: extendedDisplayLabel.leadingAnchor, constant: 16),
            allowMultipleExtendedContextsButton.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])

        // A form: nothing here can use extra room, so it stays centered.
        view = SettingsLayout.centeredRoot(around: root, width: 460)
        preferredContentSize = NSSize(width: 460, height: 290)
    }

    @objc private func viewModeChanged() {
        AppSettings.shared.defaultViewMode = viewModeControl.selectedSegment == 1 ? .sentence : .kwic
    }

    @objc private func extendedContextDisplayModeChanged() {
        AppSettings.shared.extendedContextDisplayMode = extendedContextDisplayControl.selectedSegment == 1 ? .inline : .sheet
    }

    @objc private func allowMultipleExtendedContextsChanged() {
        AppSettings.shared.allowMultipleExtendedContexts = allowMultipleExtendedContextsButton.state == .on
    }
}

extension ConcordanceSettingsViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let settings = AppSettings.shared
        switch field {
        case leftContextField:
            settings.defaultLeftContext = max(Int(field.stringValue) ?? settings.defaultLeftContext, 0)
        case rightContextField:
            settings.defaultRightContext = max(Int(field.stringValue) ?? settings.defaultRightContext, 0)
        case maxLinesField:
            settings.maxConcordanceLines = max(Int(field.stringValue.filter { $0.isASCII && $0.isNumber }) ?? settings.maxConcordanceLines, 100)
            field.stringValue = settings.maxConcordanceLines.formatted()
        case extendedContextField:
            settings.defaultExtendedContextTokens = max(Int(field.stringValue) ?? settings.defaultExtendedContextTokens, 1)
        default:
            break
        }
    }
}
