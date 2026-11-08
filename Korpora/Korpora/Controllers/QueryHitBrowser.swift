import Cocoa
import KorporaEngine

/// The query and a hit as coloured, named nodes, with arrows to step through the hits: the part the frequency and the
/// collocation sheets share (docs/frequency-composer.md). It owns the two strips and loads the hits; the sheet that
/// embeds it decides what a click on a node means.
@MainActor
final class QueryHitBrowser {
    let query: String
    let queryStrip = NodeStripView()
    let hitStrip = NodeStripView()
    let previousButton = NSButton()
    let nextButton = NSButton()
    let counterLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var nodes: QueryNodes

    /// How many hits there are to step through.
    var hitCount = 0
    /// Hit `n` as words with the words its nodes matched, given the attributes to read for each.
    var hitProvider: ((Int, [String]) async throws -> HitNodes)?
    /// The attributes read for each token of a hit (the popover shows them as examples).
    var attributes: [String] = []
    /// A click on a pickable node, with the strip it was in and the span's rectangle there.
    var onPick: ((Int, NodeStripView, NSRect) -> Void)?
    /// The node drawn stronger (the anchor of a collocation).
    var selectedNode: Int? { didSet { showQuery(); showHit() } }

    private(set) var hit: HitNodes?
    private(set) var hitIndex = 0
    private var generation = 0
    private var hitNote: String?

    init(query: String) {
        self.query = query
        nodes = QueryNodes(query)
        queryStrip.accessibilityDescription = "Query"
        hitStrip.accessibilityDescription = "First hit"
        queryStrip.onPick = { [weak self] node, rect in guard let self else { return }; onPick?(node, queryStrip, rect) }
        hitStrip.onPick = { [weak self] node, rect in guard let self else { return }; onPick?(node, hitStrip, rect) }
        configureArrow(previousButton, symbol: "chevron.left", label: "Previous hit", action: #selector(previousHit))
        configureArrow(nextButton, symbol: "chevron.right", label: "Next hit", action: #selector(nextHit))
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counterLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isHidden = true
    }

    /// "Hit", the arrows and the counter, as one row.
    lazy var hitHeader: NSView = {
        let caption = NSTextField(labelWithString: "Hit")
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        let row = NSStackView(views: [caption, previousButton, nextButton, counterLabel])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }()

    private func configureArrow(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    // MARK: Loading

    func showAll() {
        showQuery()
        updateControls()
        showHit()
    }

    func loadHit(_ index: Int) async {
        guard hitCount > 0, let hitProvider else {
            hit = nil
            showHit()
            return
        }
        generation += 1
        let mine = generation
        let wanted = max(0, min(index, hitCount - 1))
        hitNote = nil
        do {
            let fetched = try await hitProvider(wanted, attributes)
            guard mine == generation else { return }
            hit = fetched
            hitIndex = wanted
        } catch {
            guard mine == generation else { return }
            hit = nil
            hitIndex = wanted
            hitNote = "This hit can\u{2019}t be shown: \(error.localizedDescription)"
        }
        showHit()
    }

    @objc func previousHit() { Task { @MainActor in await loadHit(hitIndex - 1) } }
    @objc func nextHit() { Task { @MainActor in await loadHit(hitIndex + 1) } }

    /// The values the node has in the hit on show, when it can be told which words are the nodes.
    func samples(forNode node: Int) -> [String: String] {
        guard let hit, hit.tokens.count == nodes.nodes.count, hit.tokens.indices.contains(node) else { return [:] }
        return hit.tokens[node].attributes
    }

    // MARK: Strips

    private func tip(_ node: QueryNode) -> String {
        node.isPickable
            ? "Node \(node.name): click to choose it."
            : "Node \(node.name) can match several words or none, so it can\u{2019}t be chosen."
    }

    func showQuery() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = NSMutableAttributedString(string: query, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: NodeStripView.paragraphStyle(),
        ])
        var spans: [NodeStripView.Span] = []
        for node in nodes.nodes {
            var range = node.range
            if let mark = node.repeatMark { range.length += (mark as NSString).length }
            spans.append(.init(range: range, node: node.index, name: node.name, pickable: node.isPickable, toolTip: tip(node),
                               selected: node.index == selectedNode))
        }
        queryStrip.setContent(text, spans: spans)
        updateNote()
    }

    func showHit() {
        updateControls()
        guard let hit else {
            hitStrip.setContent(NSAttributedString(string: hitCount == 0 ? "No hits to show." : "", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: NodeStripView.paragraphStyle(),
            ]), spans: [])
            updateNote()
            return
        }
        let font = NSFont.systemFont(ofSize: 13)
        let text = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (index, word) in hit.words.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            let range = NSRange(location: text.length, length: (word as NSString).length)
            text.append(NSAttributedString(string: word, attributes: [
                .font: font, .foregroundColor: hit.matchRange.contains(index) ? NSColor.labelColor : NSColor.secondaryLabelColor,
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
                                   toolTip: node.isPickable ? tip(node) : nil, selected: node.index == selectedNode))
            }
        } else {
            note = "The words of this hit can\u{2019}t be matched to the query\u{2019}s tokens (some are optional or repeated). Click the nodes in the query above."
        }
        hitStrip.setContent(text, spans: spans)
        hitNote = note
        updateNote()
    }

    private func updateControls() {
        previousButton.isEnabled = hitCount > 1 && hitIndex > 0
        nextButton.isEnabled = hitCount > 1 && hitIndex < hitCount - 1
        counterLabel.stringValue = hitCount == 0 ? "" : "\(hitIndex + 1) of \(hitCount.formatted())"
    }

    private func updateNote() {
        var lines: [String] = []
        if let reason = nodes.unsupportedReason {
            lines.append("\(reason) Its tokens can\u{2019}t be picked.")
        }
        if let hitNote { lines.append(hitNote) }
        noteLabel.stringValue = lines.joined(separator: " ")
        noteLabel.isHidden = lines.isEmpty
    }
}
