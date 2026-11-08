import Cocoa
import KorporaEngine

/// The sheet behind the toolbar's Collocations button (docs/frequency-composer.md): the query and the first hit as
/// coloured, named nodes, then the usual form. By default the window is taken around the whole match, from its first
/// word to its last; a click on a node (or the "Around" pop-up) takes it around that one word instead, which is
/// what "the words next to the verb, not next to the whole phrase" needs.
final class CollocationComposerController: NSViewController {
    var query = ""
    var infoProvider: (() async throws -> CorpusInfo)?
    var hitCount = 0
    var hitProvider: ((Int, [String]) async throws -> HitNodes)?
    var onRun: ((CollocationSpec) -> Void)?

    static let measures: [AssociationMeasure] = [.logDice, .mutualInformation, .mi3, .tScore, .logLikelihood, .dice]
    static func displayName(_ measure: AssociationMeasure) -> String {
        switch measure {
        case .logDice: return "logDice"
        case .mutualInformation: return "MI"
        case .mi3: return "MI3"
        case .tScore: return "T-score"
        case .logLikelihood: return "Log-likelihood"
        case .dice: return "Dice"
        }
    }

    private(set) var hasLoaded = false

    private lazy var browser: QueryHitBrowser = {
        let browser = QueryHitBrowser(query: query)
        browser.hitCount = hitCount
        browser.hitProvider = hitProvider
        browser.onPick = { [weak self] node, _, _ in self?.toggleAnchor(node) }
        return browser
    }()
    var nodes: QueryNodes { browser.nodes }
    var queryStrip: NodeStripView { browser.queryStrip }
    var hitStrip: NodeStripView { browser.hitStrip }

    let aroundPopUp = NSPopUpButton()
    let attributePopUp = NSPopUpButton()
    let measurePopUp = NSPopUpButton()
    let leftWindowField = NSTextField(string: "-5")
    let rightWindowField = NSTextField(string: "5")
    let minFrequencyField = NSTextField(string: "5")
    let minCollocateFrequencyField = NSTextField(string: "3")
    let maxItemsField = NSTextField(string: "50")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let aroundHint = NSTextField(labelWithString: "")
    let runButton = NSButton(title: "Run", target: nil, action: nil)

    /// The node the window is taken around, or nil for the whole match.
    var anchor: String? {
        guard let node = browser.selectedNode, nodes.nodes.indices.contains(node) else { return nil }
        return nodes.nodes[node].name
    }

    // MARK: View

    override func loadView() {
        let title = NSTextField(labelWithString: "Collocations")
        title.font = .boldSystemFont(ofSize: 13)
        let help = NSTextField(wrappingLabelWithString:
            "Count the words around the whole match, or click a node to count around that one word only. Click it again for the whole match.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor

        let queryCaption = NSTextField(labelWithString: "Query")
        queryCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        queryCaption.textColor = .secondaryLabelColor

        measurePopUp.addItems(withTitles: Self.measures.map(Self.displayName))
        aroundPopUp.target = self
        aroundPopUp.action = #selector(aroundChanged)
        aroundPopUp.setAccessibilityLabel("Around")
        aroundHint.font = .systemFont(ofSize: 11)
        aroundHint.textColor = .secondaryLabelColor
        for field in [leftWindowField, rightWindowField, minFrequencyField, minCollocateFrequencyField, maxItemsField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }
        let window = NSStackView(views: [leftWindowField, NSTextField(labelWithString: "to"), rightWindowField])
        window.orientation = .horizontal
        window.spacing = 6

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        let grid = NSGridView(views: [
            [label("Around:"), aroundPopUp],
            [NSGridCell.emptyContentView, aroundHint],
            [label("Attribute:"), attributePopUp],
            [label("Measure:"), measurePopUp],
            [label("Window:"), window],
            [label("Min. word frequency:"), minFrequencyField],
            [label("Min. collocation frequency:"), minCollocateFrequencyField],
            [label("Max. items:"), maxItemsField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.row(at: 1).topPadding = -4
        grid.setContentHuggingPriority(.defaultHigh, for: .vertical)

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        runButton.target = self
        runButton.action = #selector(runTapped)
        runButton.keyEquivalent = "\r"
        runButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [NSView(), cancel, runButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let queryStrip = browser.queryStrip, hitStrip = browser.hitStrip, note = browser.noteLabel
        let stack = NSStackView(views: [title, help, queryCaption, queryStrip, browser.hitHeader, hitStrip, note, grid, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(10, after: help)
        stack.setCustomSpacing(10, after: queryStrip)
        stack.setCustomSpacing(10, after: hitStrip)
        stack.setCustomSpacing(14, after: note)
        for wide in [help, queryStrip, hitStrip, note, errorLabel, buttons] as [NSView] {
            wide.translatesAutoresizingMaskIntoConstraints = false
            wide.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 720),
        ])
        view = root
        preferredContentSize = NSSize(width: 720, height: 560)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        browser.showAll()
        rebuildAroundMenu()
        updateHint()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 720, height: max(view.fittingSize.height, 420))
        Task { @MainActor [weak self] in await self?.start() }
    }

    private func start() async {
        do {
            guard let info = try await infoProvider?() else { throw CancellationError() }
            attributePopUp.removeAllItems()
            attributePopUp.addItems(withTitles: info.attributes)
            // Collocates are usually looked for among lemmas.
            if let preferred = ["lemma", "form", "word"].first(where: info.attributes.contains) { attributePopUp.selectItem(withTitle: preferred) }
            browser.attributes = info.attributes
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
        }
        await browser.loadHit(0)
        hasLoaded = true
    }

    // MARK: Around

    private func rebuildAroundMenu() {
        aroundPopUp.removeAllItems()
        aroundPopUp.addItem(withTitle: "Whole match")
        for node in nodes.nodes where node.isPickable { aroundPopUp.addItem(withTitle: "Node \(node.name)") }
        selectAroundItem()
    }

    private func selectAroundItem() {
        if let name = anchor, let item = aroundPopUp.itemTitles.firstIndex(of: "Node \(name)") {
            aroundPopUp.selectItem(at: item)
        } else {
            aroundPopUp.selectItem(at: 0)
        }
    }

    @objc private func aroundChanged() {
        let title = aroundPopUp.titleOfSelectedItem ?? ""
        browser.selectedNode = nodes.nodes.first { "Node \($0.name)" == title }?.index
        updateHint()
    }

    /// A click on a node chooses it, and a second click on the same one goes back to the whole match.
    func toggleAnchor(_ node: Int) {
        browser.selectedNode = browser.selectedNode == node ? nil : node
        selectAroundItem()
        updateHint()
    }

    private func updateHint() {
        if let name = anchor {
            aroundHint.stringValue = "Around the word node \(name) matched; the other words of the match are not counted."
        } else {
            aroundHint.stringValue = "From the first word of the match to its last."
        }
    }

    // MARK: Buttons

    @objc func runTapped() {
        guard let attribute = attributePopUp.titleOfSelectedItem else {
            errorLabel.stringValue = "The corpus has no attribute to take collocates from."
            errorLabel.isHidden = false
            return
        }
        let spec = CollocationSpec(
            attribute: attribute, measure: Self.measures[max(0, measurePopUp.indexOfSelectedItem)],
            leftWindow: Int(leftWindowField.stringValue) ?? -5,
            rightWindow: Int(rightWindowField.stringValue) ?? 5,
            minFrequency: Int(minFrequencyField.stringValue) ?? 5,
            minCollocateFrequency: Int(minCollocateFrequencyField.stringValue) ?? 3,
            maxItems: Int(maxItemsField.stringValue) ?? 50,
            anchor: anchor)
        onRun?(spec)
        close()
    }

    @objc private func cancelTapped() { close() }

    private func close() { if presentingViewController != nil { dismiss(self) } }
}
