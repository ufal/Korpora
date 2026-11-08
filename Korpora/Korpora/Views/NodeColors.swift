import Cocoa

/// One colour for each node of a query, used for its span in the query, its word in a hit, its line in the
/// composer and its column in the results (docs/frequency-composer.md). The system colours adapt to dark mode.
enum NodeColors {
    static let palette: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemBrown, .systemIndigo,
    ]

    static func color(at index: Int) -> NSColor { palette[index % palette.count] }

    /// A small filled circle in the node's colour, for a menu item. Drawn on demand, so it follows light and dark.
    static func dot(at index: Int) -> NSImage {
        let color = color(at: index)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
