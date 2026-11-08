import Cocoa

/// A line of text in which some words are the nodes of a query, drawn as coloured spans with a small badge (a, b, c)
/// above each: the query itself, and a hit (docs/frequency-composer.md). A click on a node reports it, so the
/// composer can offer its attributes. Drawn with TextKit and flipped, so a span's rectangles come straight from the
/// layout manager.
final class NodeStripView: NSView, NSViewToolTipOwner {
    struct Span: Equatable {
        /// The characters of the text the node covers (UTF-16 units).
        var range: NSRange
        /// Which node: its place in the query, and so its colour.
        var node: Int
        /// The badge text: the node's name.
        var name: String
        /// False for a node that can match several words or none: drawn dashed and grey, and a click does nothing.
        var pickable = true
        var toolTip: String?
    }

    /// Called with the node and the span's first rectangle (in this view's coordinates, to anchor a popover).
    var onPick: ((Int, NSRect) -> Void)?

    private(set) var spans: [Span] = []
    /// The rectangles of each span (a span that wraps has several), in this view's coordinates.
    private(set) var spanRects: [[NSRect]] = []

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()
    private var toolTips: [NSView.ToolTipTag: String] = [:]
    private var contentHeight: CGFloat = 0

    private let inset = NSEdgeInsets(top: 17, left: 6, bottom: 5, right: 6)
    private static let badgeHeight: CGFloat = 14

    /// Said to VoiceOver ahead of the nodes.
    var accessibilityDescription = "" { didSet { setAccessibilityLabel(accessibilityDescription) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        wantsLayer = false
        setAccessibilityRole(.group)
    }

    override var isFlipped: Bool { true }

    /// Paragraph style for the text: line spacing leaves room above each line for the badges.
    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 17
        style.lineBreakMode = .byWordWrapping
        return style
    }

    func setContent(_ text: NSAttributedString, spans: [Span]) {
        storage.setAttributedString(text)
        self.spans = spans
        relayout()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        relayout()
    }

    private var laidOutWidth: CGFloat = -1

    private func relayout() {
        let width = max((bounds.width > 0 ? bounds.width : 600) - inset.left - inset.right, 20)
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let height = ceil(used.height) + inset.top + inset.bottom
        spanRects = spans.map { span in
            var rects: [NSRect] = []
            guard span.range.length > 0, NSMaxRange(span.range) <= storage.length else { return rects }
            let glyphs = layoutManager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                rects.append(rect.offsetBy(dx: self.inset.left, dy: self.inset.top).insetBy(dx: -2, dy: 0))
            }
            return rects
        }
        if height != contentHeight {
            contentHeight = height
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        resetToolTips()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: max(contentHeight, 24)) }

    // MARK: Drawing

    private func badgeRect(for index: Int) -> NSRect? {
        guard let first = spanRects[index].first else { return nil }
        let name = spans[index].name as NSString
        let width = max(Self.badgeHeight, ceil(name.size(withAttributes: [.font: Self.badgeFont]).width) + 8)
        return NSRect(x: first.minX, y: first.minY - Self.badgeHeight - 1, width: width, height: Self.badgeHeight)
    }

    private static let badgeFont = NSFont.systemFont(ofSize: 9, weight: .bold)

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, span) in spans.enumerated() {
                let color = span.pickable ? NodeColors.color(at: span.node) : NSColor.secondaryLabelColor
                for rect in spanRects[index] {
                    let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                    color.withAlphaComponent(span.pickable ? 0.22 : 0.10).setFill()
                    path.fill()
                    color.withAlphaComponent(0.85).setStroke()
                    path.lineWidth = 1
                    if !span.pickable { path.setLineDash([3, 2], count: 2, phase: 0) }
                    path.stroke()
                }
            }
            let glyphs = layoutManager.glyphRange(for: container)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: inset.left, y: inset.top))
            for (index, span) in spans.enumerated() {
                guard let rect = badgeRect(for: index) else { continue }
                let color = span.pickable ? NodeColors.color(at: span.node) : NSColor.secondaryLabelColor
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
                let text = span.name as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: Self.badgeFont, .foregroundColor: NSColor.white]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }

    // MARK: Clicks, cursor, tooltips

    /// The node under `point` (this view's coordinates): its span or its badge. Nil for a node that can't be picked.
    func pickableNode(at point: NSPoint) -> Int? {
        for (index, span) in spans.enumerated() where span.pickable {
            if spanRects[index].contains(where: { $0.contains(point) }) { return span.node }
            if let badge = badgeRect(for: index), badge.contains(point) { return span.node }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let node = pickableNode(at: point),
              let index = spans.firstIndex(where: { $0.node == node && $0.pickable }),
              let rect = spanRects[index].first else {
            super.mouseDown(with: event)
            return
        }
        onPick?(node, rect)
    }

    override func resetCursorRects() {
        for (index, span) in spans.enumerated() where span.pickable {
            for rect in spanRects[index] { addCursorRect(rect, cursor: .pointingHand) }
        }
    }

    private func resetToolTips() {
        removeAllToolTips()
        toolTips = [:]
        for (index, span) in spans.enumerated() {
            guard let text = span.toolTip, let first = spanRects[index].first else { continue }
            let area = badgeRect(for: index).map { first.union($0) } ?? first
            toolTips[addToolTip(area, owner: self, userData: nil)] = text
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        toolTips[tag] ?? ""
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        spans.enumerated().compactMap { index, span in
            guard let rect = spanRects[index].first else { return nil }
            let element = NodeAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Node \(span.name)" + (span.pickable ? ", choose an attribute" : ", can\u{2019}t be chosen"))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect)
            element.onPress = span.pickable ? { [weak self] in self?.onPick?(span.node, rect) } : nil
            return element
        }
    }
}

private final class NodeAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
