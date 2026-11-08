import AppKit
import Foundation
import Testing
import KorporaEngine
@testable import Korpora

@MainActor @Suite(.serialized) struct FrequencyComposerTests {
    private let info = CorpusInfo(name: "c", sizeTokens: 100, attributes: ["form", "lemma", "upos"],
                                  structures: [StructureInfo(name: "doc", attributes: ["genre", "title"])])

    /// "the cat eats fish": the verb (node a) is word 2, its subject (node b) word 1.
    private let hit = HitNodes(
        words: ["the", "cat", "eats", "fish", "."], matchRange: 1..<3,
        tokens: [.init(wordIndex: 2, attributes: ["form": "eats", "lemma": "eat", "upos": "VERB"]),
                 .init(wordIndex: 1, attributes: ["form": "cat", "lemma": "cat", "upos": "NOUN"])])

    private func composer(query: String = #"[upos="VERB"] > [deprel="nsubj"]"#, hits: Int = 3,
                          provider: ((Int, [String]) async throws -> HitNodes)? = nil) async -> FrequencyComposerController {
        let controller = FrequencyComposerController()
        controller.query = query
        controller.hitCount = hits
        controller.infoProvider = { [info] in info }
        controller.hitProvider = provider ?? { [hit] _, _ in hit }
        _ = controller.view
        for _ in 0..<500 where !controller.hasLoaded { try? await Task.sleep(for: .milliseconds(5)) }
        return controller
    }

    @Test func startsWithTheFormOfTheFirstNode() async {
        let c = await composer()
        #expect(c.model.fields == [FrequencyField(node: "a", attribute: "form")])
        #expect(c.nodes.nodes.map(\.name) == ["a", "b"])
    }

    @Test func theQueryStripHasANodeForEachToken() async {
        let c = await composer()
        #expect(c.queryStrip.spans.map(\.name) == ["a", "b"])
        #expect(c.queryStrip.spans.map(\.pickable) == [true, true])
    }

    @Test func theHitStripColoursTheWordsEachNodeMatchedInQueryOrder() async {
        let c = await composer()
        let spans = c.hitStrip.spans
        #expect(spans.map(\.name) == ["a", "b"])
        let text = c.hitStrip.spans.map { span -> String in
            // The strip's text is the words joined by single spaces.
            let words = ["the", "cat", "eats", "fish", "."].joined(separator: " ") as NSString
            return words.substring(with: span.range)
        }
        #expect(text == ["eats", "cat"], "node a is the verb, node b the subject, though it stands first")
    }

    @Test func pickingAnAttributeAddsALineAndTheSameOneTwiceDoesNot() async {
        let c = await composer()
        c.pick(node: "b", attribute: "lemma")
        #expect(c.model.fields == [FrequencyField(node: "a", attribute: "form"), FrequencyField(node: "b", attribute: "lemma")])
        c.pick(node: "b", attribute: "lemma")
        #expect(c.model.fieldRows.count == 2)
    }

    @Test func theArrowsStepThroughTheHitsAndStopAtTheEnds() async {
        var asked: [Int] = []
        let c = await composer(hits: 3) { [hit] index, _ in asked.append(index); return hit }
        #expect(c.counterLabel.stringValue == "1 of 3")
        #expect(!c.previousButton.isEnabled && c.nextButton.isEnabled)
        c.nextHit()
        for _ in 0..<200 where c.counterLabel.stringValue != "2 of 3" { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(c.counterLabel.stringValue == "2 of 3")
        c.nextHit()
        for _ in 0..<200 where c.counterLabel.stringValue != "3 of 3" { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(c.counterLabel.stringValue == "3 of 3")
        #expect(!c.nextButton.isEnabled && c.previousButton.isEnabled)
        #expect(asked == [0, 1, 2])
    }

    @Test func theHitIsAskedForEveryAttributeSoThePopoverCanShowTheValues() async {
        var attributes: [String] = []
        _ = await composer { [hit] _, wanted in attributes = wanted; return hit }
        #expect(attributes == ["form", "lemma", "upos"])
    }

    @Test func aHitThatCannotBeMatchedToTheNodesLeavesTheWordsUncoloured() async {
        let odd = HitNodes(words: ["a", "b", "c"], matchRange: 0..<3, tokens: [.init(wordIndex: 0, attributes: [:])])
        let c = await composer(provider: { _, _ in odd })
        for _ in 0..<100 where c.noteLabel.isHidden { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(c.hitStrip.spans.isEmpty)
        #expect(!c.noteLabel.isHidden)
        #expect(c.noteLabel.stringValue.contains("can\u{2019}t be matched"))
    }

    @Test func aRepeatedNodeIsShownButCannotBePickedOrCounted() async {
        let c = await composer(query: #"[upos="ADJ"]{1,2} [upos="NOUN"]"#)
        #expect(c.queryStrip.spans.map(\.pickable) == [false, true])
        #expect(c.model.fields == [FrequencyField(node: "b", attribute: "form")], "the default line skips it")
    }

    @Test func aDialectQueryHasNoNodesButSaysWhy() async {
        let controller = FrequencyComposerController()
        controller.query = #"MANATEE [word="a"]"#
        controller.infoProvider = { [info] in info }
        _ = controller.view
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.queryStrip.spans.isEmpty)
        #expect(!controller.noteLabel.isHidden)
        #expect(controller.model.isEmpty)
    }

    @Test func runningHandsOverTheFieldsTheOrderAndTheMinimum() async {
        let c = await composer()
        c.pick(node: "b", attribute: "lemma")
        c.model.cycleSort(for: c.model.rows[1].id)
        c.minFrequencyField.stringValue = "3"
        var got: ([FrequencyField], [FrequencySortKey], Int)?
        c.onRun = { fields, keys, minimum, _ in got = (fields, keys, minimum) }
        c.runTapped()
        #expect(got?.0 == [FrequencyField(node: "a", attribute: "form"), FrequencyField(node: "b", attribute: "lemma")])
        #expect(got?.1 == [FrequencySortKey(.field(1), ascending: true)])
        #expect(got?.2 == 3)
    }

    @Test func runningWithNothingChosenSaysSoAndRunsNothing() async {
        let c = await composer(query: #"[upos="ADJ"]*"#)
        #expect(c.model.isEmpty)
        var ran = false
        c.onRun = { _, _, _, _ in ran = true }
        c.runTapped()
        #expect(!ran)
    }

    @Test func noHitsLeavesTheArrowsOffAndTheQueryStillWorks() async {
        let c = await composer(hits: 0)
        #expect(!c.previousButton.isEnabled && !c.nextButton.isEnabled)
        #expect(c.counterLabel.stringValue.isEmpty)
        #expect(c.queryStrip.spans.count == 2)
    }

    /// With `KORPORA_SNAPSHOT_DIR` set, the composer is rendered to a PNG there, for a look.
    @Test func snapshot() async throws {
        guard let dir = ProcessInfo.processInfo.environment["KORPORA_SNAPSHOT_DIR"] else { return }
        let c = await composer(query: #"[lemma="give"] > [deprel="obj"]"#)
        c.pick(node: "b", attribute: "upos")
        c.model.cycleSort(for: c.model.rows[1].id)
        let window = NSWindow(contentViewController: c)
        window.setContentSize(c.preferredContentSize)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            window.contentView?.layoutSubtreeIfNeeded()
            let view = try #require(window.contentView)
            view.wantsLayer = true
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("composer-\(name == .aqua ? "light" : "dark").png"))
        }
    }
}
