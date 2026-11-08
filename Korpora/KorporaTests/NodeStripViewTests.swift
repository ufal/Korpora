import AppKit
import Foundation
import Testing
import KorporaEngine
@testable import Korpora

@MainActor @Suite struct NodeStripViewTests {
    private func strip(_ query: String, width: CGFloat = 520) -> (NodeStripView, QueryNodes) {
        let nodes = QueryNodes(query)
        let view = NodeStripView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        let text = NSAttributedString(string: query, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .paragraphStyle: NodeStripView.paragraphStyle(),
        ])
        let spans = nodes.nodes.map {
            NodeStripView.Span(range: $0.range, node: $0.index, name: $0.name, pickable: $0.isPickable, toolTip: "tip \($0.name)")
        }
        view.setContent(text, spans: spans)
        view.layoutSubtreeIfNeeded()
        return (view, nodes)
    }

    @Test func everyNodeGetsARectangleInQueryOrder() {
        let (view, _) = strip(#"[lemma="give"] > [deprel="obj"]"#)
        #expect(view.spanRects.count == 2)
        #expect(view.spanRects.allSatisfy { !$0.isEmpty })
        #expect(view.spanRects[0][0].maxX < view.spanRects[1][0].minX, "the first node is to the left of the second")
    }

    @Test func aClickOnANodeOrItsBadgeFindsIt() {
        let (view, _) = strip(#"[lemma="give"] > [deprel="obj"]"#)
        let first = view.spanRects[0][0], second = view.spanRects[1][0]
        #expect(view.pickableNode(at: NSPoint(x: first.midX, y: first.midY)) == 0)
        #expect(view.pickableNode(at: NSPoint(x: second.midX, y: second.midY)) == 1)
        // The badge sits just above the span's left end.
        #expect(view.pickableNode(at: NSPoint(x: first.minX + 4, y: first.minY - 6)) == 0)
        // The arrow between them is nothing.
        let gap = NSPoint(x: (first.maxX + second.minX) / 2, y: first.midY)
        #expect(view.pickableNode(at: gap) == nil)
    }

    @Test func aNodeThatMayRepeatCannotBePicked() {
        let (view, nodes) = strip(#"[upos="ADJ"]{1,2} [upos="NOUN"]"#)
        #expect(nodes.nodes.map(\.isPickable) == [false, true])
        let first = view.spanRects[0][0], second = view.spanRects[1][0]
        #expect(view.pickableNode(at: NSPoint(x: first.midX, y: first.midY)) == nil)
        #expect(view.pickableNode(at: NSPoint(x: second.midX, y: second.midY)) == 1)
    }

    @Test func aLongQueryWrapsAndTheHeightGrowsWithIt() {
        let query = (0..<12).map { #"[lemma="word\#($0)"]"# }.joined(separator: " ")
        let (narrow, _) = strip(query, width: 300)
        let (wide, _) = strip(query, width: 1800)
        #expect(narrow.intrinsicContentSize.height > wide.intrinsicContentSize.height)
        // Every node still has its rectangle, and the later ones are on lower lines.
        #expect(narrow.spanRects.allSatisfy { !$0.isEmpty })
        #expect(narrow.spanRects.last![0].minY > narrow.spanRects.first![0].minY)
    }

    @Test func aSpanThatWrapsHasARectangleForEachLine() {
        let query = #"a:[lemma="a very long value that has to wrap over more than one line of a narrow strip"]"#
        let (view, _) = strip(query, width: 240)
        #expect(view.spanRects[0].count > 1)
    }

    @Test func clickingCallsBackWithTheNodeAndItsRectangle() {
        let (view, _) = strip(#"[lemma="give"] [deprel="obj"]"#)
        var picked: (Int, NSRect)?
        view.onPick = { picked = ($0, $1) }
        let second = view.spanRects[1][0]
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let point = view.convert(NSPoint(x: second.midX, y: second.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: event)
        #expect(picked?.0 == 1)
        #expect(picked?.1 == second)
    }

    @Test func accessibilityOffersAButtonForEachNode() {
        let (view, _) = strip(#"[lemma="give"] [upos="ADJ"]*"#)
        let children = view.accessibilityChildren() ?? []
        #expect(children.count == 2)
        let labels = children.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(labels.first == "Node a, choose an attribute")
        #expect(labels.last?.contains("can\u{2019}t be chosen") == true)
    }

    @Test func paintingDoesNotCrashAndDrawsInBothAppearances() throws {
        let (view, _) = strip(#"[lemma="give"] > [deprel="obj"]"#)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: name)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            #expect(rep.pixelsWide > 0)
        }
    }
}
