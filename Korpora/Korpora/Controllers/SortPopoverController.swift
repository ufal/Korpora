import Cocoa
import KorporaEngine

/// Content of the toolbar's Sort popover: one sort level (the model has up to four - see
/// `SortCriteria` - but a UI for that isn't worth building until someone needs it).
///
/// The hit itself can be sorted by any token attribute; the words around it only by their spelling,
/// since that is all a search result carries for them (docs/pando-gui-plan.md).
final class SortPopoverController: NSViewController {
    var onApply: ((SortCriteria) -> Void)?
    /// The corpus's token attributes, the attribute of its text (`form`) and the one currently shown.
    var attributes: [String] = []
    var textAttribute = "form"
    var shownAttribute = "form"

    private let anchorPopUp = NSPopUpButton()
    private let attributePopUp = NSPopUpButton()
    private let spanField = NSTextField(string: "1")
    private let spanLabel = NSTextField(labelWithString: "Words:")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let caseInsensitiveCheckbox = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)
    // Not a sort-direction toggle - every sort here is ascending. It compares each word spelled
    // backwards, e.g. for sorting by word ending rather than word start.
    private let reverseCheckbox = NSButton(checkboxWithTitle: "By word ending", target: nil, action: nil)

    private enum Anchor: Int { case left, hit, right }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 220))

        anchorPopUp.addItems(withTitles: ["The words to the left", "The hit", "The words to the right"])
        anchorPopUp.selectItem(at: Anchor.hit.rawValue)
        anchorPopUp.target = self
        anchorPopUp.action = #selector(anchorChanged)

        let names = attributes.isEmpty ? [textAttribute] : attributes
        attributePopUp.addItems(withTitles: names)
        attributePopUp.selectItem(withTitle: names.contains(shownAttribute) ? shownAttribute : textAttribute)

        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor

        let sortLabel = NSTextField(labelWithString: "Sort by:")
        let attrLabel = NSTextField(labelWithString: "Attribute:")
        let applyButton = NSButton(title: "Sort", target: self, action: #selector(applyTapped))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded

        let views: [NSView] = [
            sortLabel, anchorPopUp, attrLabel, attributePopUp, spanLabel, spanField, noteLabel,
            caseInsensitiveCheckbox, reverseCheckbox, applyButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        spanField.widthAnchor.constraint(equalToConstant: 50).isActive = true

        NSLayoutConstraint.activate([
            sortLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            sortLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            anchorPopUp.centerYAnchor.constraint(equalTo: sortLabel.centerYAnchor),
            anchorPopUp.leadingAnchor.constraint(equalTo: sortLabel.trailingAnchor, constant: 8),

            attrLabel.topAnchor.constraint(equalTo: sortLabel.bottomAnchor, constant: 14),
            attrLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            attributePopUp.centerYAnchor.constraint(equalTo: attrLabel.centerYAnchor),
            attributePopUp.leadingAnchor.constraint(equalTo: attrLabel.trailingAnchor, constant: 8),

            spanLabel.topAnchor.constraint(equalTo: attrLabel.bottomAnchor, constant: 14),
            spanLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            spanField.centerYAnchor.constraint(equalTo: spanLabel.centerYAnchor),
            spanField.leadingAnchor.constraint(equalTo: spanLabel.trailingAnchor, constant: 8),

            noteLabel.topAnchor.constraint(equalTo: spanLabel.bottomAnchor, constant: 8),
            noteLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            noteLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            caseInsensitiveCheckbox.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 10),
            caseInsensitiveCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            reverseCheckbox.topAnchor.constraint(equalTo: caseInsensitiveCheckbox.bottomAnchor, constant: 8),
            reverseCheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            applyButton.topAnchor.constraint(equalTo: reverseCheckbox.bottomAnchor, constant: 16),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        preferredContentSize = root.frame.size
        anchorChanged()
    }

    private var anchor: Anchor { Anchor(rawValue: anchorPopUp.indexOfSelectedItem) ?? .hit }

    /// The words around a hit are sorted by spelling only: the attribute is fixed, and says why.
    @objc private func anchorChanged() {
        let around = anchor != .hit
        attributePopUp.isEnabled = !around
        if around { attributePopUp.selectItem(withTitle: textAttribute) }
        spanLabel.isHidden = !around
        spanField.isHidden = !around
        noteLabel.stringValue = around
            ? "The words around a hit are sorted by their spelling (\(textAttribute))." : ""
    }

    @objc private func applyTapped() {
        let sortAnchor: SortAnchor
        switch anchor {
        case .left: sortAnchor = .left
        case .right: sortAnchor = .right
        case .hit: sortAnchor = .kwic
        }
        let level = SortLevel(
            attribute: attributePopUp.titleOfSelectedItem ?? textAttribute,
            anchor: sortAnchor,
            span: max(Int(spanField.stringValue) ?? 1, 1),
            caseInsensitive: caseInsensitiveCheckbox.state == .on,
            reverse: reverseCheckbox.state == .on)
        onApply?(SortCriteria(level))
    }
}
