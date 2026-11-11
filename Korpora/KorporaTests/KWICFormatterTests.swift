import AppKit
import Foundation
import Testing
import KorporaEngine
@testable import Korpora

@Suite struct KWICFormatterTests {
    private let tokens = [
        KWICToken(word: "the", secondaryAttributes: ["lemma": "the", "tag": "DT"]),
        KWICToken(word: "fox", secondaryAttributes: ["lemma": "fox", "tag": "NN"]),
    ]

    @Test func displayLineIsPerTokenWordSegmentsWithoutInlineAttributes() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: [], tooltipAttributes: [])
        #expect(line.segments == [
            KWICDisplaySegment(text: "the", kind: .word),
            KWICDisplaySegment(text: " ", kind: .word),
            KWICDisplaySegment(text: "fox", kind: .word),
        ])
        #expect(line.tokenTooltips.isEmpty)
    }

    @Test func aWordBetweenTheMatchedTokensIsMarkedAsNotMatched() {
        let tokens = [
            KWICToken(word: "the", secondaryAttributes: [:]),
            KWICToken(word: "big", secondaryAttributes: [:], isMatch: false),
            KWICToken(word: "cat", secondaryAttributes: [:]),
        ]
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: [], tooltipAttributes: [])
        #expect(line.segments.map(\.isMatch) == [true, false, false, false, true])
        // In the Match column that word, and the spaces next to it, are plain; elsewhere nothing changes.
        #expect(KWICCellView.style(of: line.segments[2], in: .highlighted) == .plain)
        #expect(KWICCellView.style(of: line.segments[0], in: .highlighted) == .highlighted)
        #expect(KWICCellView.style(of: line.segments[2], in: .plain) == .plain)
    }

    @Test func theMatchColorIsRedUntilTheUserChoosesAndTheChoiceIsKept() throws {
        let suite = "korpora.test.matchcolor.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.matchColor == NSColor.systemRed)
        settings.matchColor = NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1)
        let again = AppSettings(defaults: defaults).matchColor.usingColorSpace(.sRGB)
        #expect(again?.greenComponent == 0.5)
    }

    @Test func displayLineAppendsInlineAttributesAsSecondarySegments() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: ["tag"], tooltipAttributes: [])
        #expect(line.segments == [
            KWICDisplaySegment(text: "the", kind: .word),
            KWICDisplaySegment(text: "/DT", kind: .secondaryAttribute),
            KWICDisplaySegment(text: " ", kind: .word),
            KWICDisplaySegment(text: "fox", kind: .word),
            KWICDisplaySegment(text: "/NN", kind: .secondaryAttribute),
        ])
    }

    @Test func displayLineCombinesMultipleInlineAttributesInOneSecondarySegment() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: ["lemma", "tag"], tooltipAttributes: [])
        #expect(line.segments.filter { $0.kind == .secondaryAttribute }.map(\.text) == ["/the/DT", "/fox/NN"])
    }

    @Test func displayLineSkipsSecondarySegmentForATokenMissingTheRequestedAttribute() {
        let partial = [KWICToken(word: "the", secondaryAttributes: [:])]
        let line = KWICFormatter.displayLine(for: partial, inlineAttributes: ["tag"], tooltipAttributes: [])
        #expect(line.segments == [KWICDisplaySegment(text: "the", kind: .word)])
    }

    @Test func displayLineHasNoTooltipsWithoutTooltipAttributes() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: [], tooltipAttributes: [])
        #expect(line.tokenTooltips.isEmpty)
    }

    @Test func displayLineTooltipsAreOnePerTokenNotOneForTheWholeLine() {
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: [], tooltipAttributes: ["lemma", "tag"])
        #expect(line.tokenTooltips.count == 2)
        #expect(line.tokenTooltips[0].text == "lemma: the, tag: DT")
        #expect(line.tokenTooltips[1].text == "lemma: fox, tag: NN")
    }

    @Test func tooltipSegmentRangesPointAtThatTokensOwnSegmentsOnly() {
        // With "tag" both inline and on hover, each token contributes 2
        // segments (word + its "/tag" suffix) - the tooltip's range must
        // cover only *that* token's 2 segments, not the whole line's.
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: ["tag"], tooltipAttributes: ["tag"])
        #expect(line.segments.count == 5) // the, /DT, " ", fox, /NN
        #expect(line.tokenTooltips.map(\.segmentRange) == [0..<2, 3..<5])
    }

    @Test func inlineAndTooltipAttributesCanOverlapOrDiffer() {
        // The combination the user specifically asked for: "tag" inline,
        // "lemma" only on hover, at the same time - not mutually exclusive.
        let line = KWICFormatter.displayLine(for: tokens, inlineAttributes: ["tag"], tooltipAttributes: ["lemma"])
        #expect(line.segments.filter { $0.kind == .secondaryAttribute }.map(\.text) == ["/DT", "/NN"])
        #expect(line.tokenTooltips.map(\.text) == ["lemma: the", "lemma: fox"])
    }
}
