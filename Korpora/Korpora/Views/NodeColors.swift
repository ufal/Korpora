import Cocoa

/// One colour for each node of a query, used for its span in the query, its word in a hit, its line in the
/// composer and its column in the results (docs/frequency-composer.md). The system colours adapt to dark mode.
enum NodeColors {
    static let palette: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemBrown, .systemIndigo,
    ]

    static func color(at index: Int) -> NSColor { palette[index % palette.count] }
}
