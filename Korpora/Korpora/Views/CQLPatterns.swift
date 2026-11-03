import Cocoa

/// Query patterns for the query bar's "Insert pattern" menu: starting points for the parts of
/// pando-CQL that are hard to type from memory, above all dependency relations (pando-CQL
/// reference, "Dependency relations"). Each one is plain pando-CQL; `caret` marks where the cursor
/// goes, so the pattern can be filled in at once.
struct CQLPattern {
    /// Where the caret goes in `template` (removed on insertion).
    static let caret = "\u{2038}"

    let title: String
    let template: String
    /// What it finds, in words, as a tooltip.
    let detail: String
    /// Attribute names the corpus must have for the pattern to make sense (UD examples).
    var requires: [String] = []

    /// The text to insert and where the caret goes in it (UTF-16 offset).
    var insertion: (text: String, caretOffset: Int) {
        let ns = template as NSString
        let marker = ns.range(of: Self.caret)
        guard marker.location != NSNotFound else { return (template, ns.length) }
        return (ns.replacingCharacters(in: marker, with: ""), marker.location)
    }
}

enum CQLPatterns {
    /// A group of patterns under a heading.
    struct Section {
        let heading: String
        let patterns: [CQLPattern]
    }

    static let sections: [Section] = [
        Section(heading: "Dependencies: inside a word", patterns: [
            CQLPattern(
                title: "Word with a dependent", template: "[child [\(CQLPattern.caret)]]",
                detail: "A word that has a dependent (a child in the dependency tree) matching the inner brackets: "
                    + "[upos=\"NOUN\" & child [upos=\"DET\"]] is a noun with a determiner."),
            CQLPattern(
                title: "Word whose head is\u{2026}", template: "[parent [\(CQLPattern.caret)]]",
                detail: "A word whose head (parent) matches the inner brackets. ancestor, descendant and sibling work the same way."),
            CQLPattern(
                title: "Word without a dependent\u{2026}", template: "[not child [\(CQLPattern.caret)]]",
                detail: "A word that has no dependent matching the inner brackets. not also works with parent, next and the others."),
            CQLPattern(
                title: "Word with at least two dependents\u{2026}", template: "[count(child [\(CQLPattern.caret)]) >= 2]",
                detail: "A word with at least two dependents matching the inner brackets."),
            CQLPattern(
                title: "Word not followed by\u{2026}", template: "[not next [\(CQLPattern.caret)]]",
                detail: "next and prev are the word right after and right before; after and before are any later or earlier word "
                    + "in the sentence. They are most useful with not."),
        ]),
        Section(heading: "Dependencies: between two words", patterns: [
            CQLPattern(
                title: "Head \u{2192} dependent", template: "[\(CQLPattern.caret)] > []",
                detail: "Two words where the first is the head of the second: [lemma=\"book\"] > [upos=\"DET\"]. "
                    + "The arrow points from the head to the dependent."),
            CQLPattern(
                title: "Dependent \u{2192} head", template: "[\(CQLPattern.caret)] < []",
                detail: "Two words where the first depends on the second: [upos=\"DET\"] < [lemma=\"book\"]."),
            CQLPattern(
                title: "Anywhere below (any distance)", template: "[\(CQLPattern.caret)] >> []",
                detail: ">> is a word anywhere below the first in the tree, << anywhere above. > and < are direct links only."),
            CQLPattern(
                title: "Head without a dependent\u{2026}", template: "[\(CQLPattern.caret)] !> []",
                detail: "The first word without a dependent matching the second (which is not part of the hit): "
                    + "[upos=\"NOUN\"] !> [upos=\"DET\"] finds nouns without a determiner. !< is the other direction."),
        ]),
        Section(heading: "Universal Dependencies examples", patterns: [
            CQLPattern(
                title: "Noun with a determiner", template: #"[upos="NOUN" & child [upos="DET"]]"#,
                detail: "Nouns that have a determiner as a dependent.", requires: ["upos"]),
            CQLPattern(
                title: "Verb without a subject", template: #"[upos="VERB" & not child [deprel="nsubj"]]"#,
                detail: "Verbs with no nominal subject.", requires: ["upos", "deprel"]),
            CQLPattern(
                title: "Adjective after its noun", template: #"a:[upos="ADJ"] < b:[upos="NOUN"] :: a > b"#,
                detail: "Adjectives that depend on a noun and come after it. After :: the signs < and > compare positions, "
                    + "so a > b means a comes after b.", requires: ["upos"]),
        ]),
        Section(heading: "Regions", patterns: [
            CQLPattern(
                title: "Within a sentence", template: "[\(CQLPattern.caret)] within s",
                detail: "The whole match inside one sentence."),
            CQLPattern(
                title: "Sequence of words", template: "[\(CQLPattern.caret)] [] []",
                detail: "Three words in a row. Add ? * + or {1,3} after a bracket to repeat it."),
        ]),
    ]

    /// The menu for the "Insert pattern" button. Patterns that need attributes the corpus lacks
    /// are shown, but disabled.
    @MainActor
    static func makeMenu(target: AnyObject, action: Selector, availableAttributes: Set<String>?) -> NSMenu {
        let menu = NSMenu(title: "Insert pattern")
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: section.heading, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for pattern in section.patterns {
                let item = NSMenuItem(title: pattern.title, action: action, keyEquivalent: "")
                item.target = target
                item.representedObject = pattern.template
                item.toolTip = pattern.detail
                item.indentationLevel = 1
                if let availableAttributes, !pattern.requires.allSatisfy(availableAttributes.contains) {
                    item.action = nil  // greyed out: this corpus has no such attribute
                    item.toolTip = (item.toolTip ?? "") + " (This corpus has no \(pattern.requires.joined(separator: ", ")).)"
                }
                menu.addItem(item)
            }
        }
        return menu
    }
}
