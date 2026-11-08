import AppKit
import Foundation
import Testing
import KorporaEngine
@testable import Korpora

@MainActor @Suite(.serialized) struct CollocationComposerTests {
    private let info = CorpusInfo(name: "c", sizeTokens: 100, attributes: ["form", "lemma", "upos"], structures: [])
    private let hit = HitNodes(
        words: ["the", "cat", "eats", "fish", "."], matchRange: 1..<3,
        tokens: [.init(wordIndex: 2, attributes: [:]), .init(wordIndex: 1, attributes: [:])])

    private func composer(query: String = #"[upos="VERB"] > [deprel="nsubj"]"#) async -> CollocationComposerController {
        let controller = CollocationComposerController()
        controller.query = query
        controller.hitCount = 2
        controller.infoProvider = { [info] in info }
        controller.hitProvider = { [hit] _, _ in hit }
        _ = controller.view
        for _ in 0..<500 where !controller.hasLoaded { try? await Task.sleep(for: .milliseconds(5)) }
        return controller
    }

    private func run(_ c: CollocationComposerController) -> CollocationSpec? {
        var spec: CollocationSpec?
        c.onRun = { spec = $0 }
        c.runTapped()
        return spec
    }

    @Test func startsAroundTheWholeMatchOnLemmas() async {
        let c = await composer()
        let spec = run(c)
        #expect(spec?.anchor == nil)
        #expect(spec?.attribute == "lemma")
        #expect(spec?.leftWindow == -5 && spec?.rightWindow == 5)
        #expect(spec?.measure == .logDice)
        #expect(c.aroundPopUp.itemTitles == ["Whole match", "Node a", "Node b"])
    }

    @Test func aClickOnANodeTakesTheWindowAroundItAndASecondClickGoesBack() async {
        let c = await composer()
        c.toggleAnchor(1)
        #expect(c.anchor == "b")
        #expect(c.aroundPopUp.titleOfSelectedItem == "Node b")
        #expect(c.queryStrip.spans.map(\.selected) == [false, true])
        #expect(c.hitStrip.spans.map(\.selected) == [false, true])
        #expect(run(c)?.anchor == "b")
        c.toggleAnchor(1)
        #expect(c.anchor == nil)
        #expect(c.aroundPopUp.titleOfSelectedItem == "Whole match")
        #expect(c.queryStrip.spans.allSatisfy { !$0.selected })
    }

    @Test func clickingAnotherNodeMovesTheAnchor() async {
        let c = await composer()
        c.toggleAnchor(0)
        c.toggleAnchor(1)
        #expect(c.anchor == "b")
    }

    @Test func thePopUpChoosesTheAnchorToo() async {
        let c = await composer()
        c.aroundPopUp.selectItem(withTitle: "Node a")
        _ = c.aroundPopUp.sendAction(c.aroundPopUp.action, to: c.aroundPopUp.target)
        #expect(c.anchor == "a")
        #expect(c.queryStrip.spans.map(\.selected) == [true, false])
        c.aroundPopUp.selectItem(withTitle: "Whole match")
        _ = c.aroundPopUp.sendAction(c.aroundPopUp.action, to: c.aroundPopUp.target)
        #expect(c.anchor == nil)
    }

    @Test func aNodeThatMayRepeatIsNotOffered() async {
        let c = await composer(query: #"[upos="ADJ"]{1,2} [upos="NOUN"]"#)
        #expect(c.aroundPopUp.itemTitles == ["Whole match", "Node b"])
    }

    @Test func theUsersOwnNamesAreTheNodesNames() async {
        let c = await composer(query: #"verb:[upos="VERB"] > []"#)
        #expect(c.aroundPopUp.itemTitles == ["Whole match", "Node verb", "Node a"])
        c.toggleAnchor(0)
        #expect(run(c)?.anchor == "verb")
    }

    @Test func theFormIsReadIntoTheSpec() async {
        let c = await composer()
        c.leftWindowField.stringValue = "-2"
        c.rightWindowField.stringValue = "3"
        c.minFrequencyField.stringValue = "7"
        c.minCollocateFrequencyField.stringValue = "4"
        c.maxItemsField.stringValue = "20"
        c.measurePopUp.selectItem(withTitle: "MI")
        c.attributePopUp.selectItem(withTitle: "form")
        let spec = run(c)
        #expect(spec?.leftWindow == -2 && spec?.rightWindow == 3)
        #expect(spec?.minFrequency == 7 && spec?.minCollocateFrequency == 4 && spec?.maxItems == 20)
        #expect(spec?.measure == .mutualInformation)
        #expect(spec?.attribute == "form")
    }

    @Test func aQueryWithoutTokensOnlyOffersTheWholeMatch() async {
        let c = await composer(query: "<s>")
        #expect(c.aroundPopUp.itemTitles == ["Whole match"])
        #expect(run(c)?.anchor == nil)
    }

    @Test func theResultsWindowSaysWhatTheWindowWasTakenAround() {
        let spec = CollocationSpec(attribute: "lemma", leftWindow: -2, rightWindow: 2, anchor: "a")
        let window = CollocationWindowController(spec: spec, items: [CollocationItem(word: "x", freq: 1, cnt: 1, score: 1)])
        #expect(window.window?.title == "Collocations: lemma (around a)")
        let whole = CollocationWindowController(spec: CollocationSpec(attribute: "lemma"), items: [])
        #expect(whole.window?.title == "Collocations: lemma")
    }

    @Test func snapshot() async throws {
        guard let dir = ProcessInfo.processInfo.environment["KORPORA_SNAPSHOT_DIR"] else { return }
        let c = await composer(query: #"[lemma="give"] > [deprel="obj"]"#)
        c.toggleAnchor(0)
        let window = NSWindow(contentViewController: c)
        window.setContentSize(c.preferredContentSize)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            window.contentView?.layoutSubtreeIfNeeded()
            let view = try #require(window.contentView)
            view.wantsLayer = true
            window.effectiveAppearance.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("collocations-\(name == .aqua ? "light" : "dark").png"))
        }
    }
}
