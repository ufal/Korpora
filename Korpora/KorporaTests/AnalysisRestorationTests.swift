import AppKit
import Foundation
import Testing
import KorporaEngine
@testable import Korpora

@MainActor @Suite(.serialized) struct AnalysisRestorationTests {
    private let frequency = AnalysisState.frequency(
        fields: [FrequencyField(node: "a", attribute: "lemma", ignoreCase: true), FrequencyField(node: nil, attribute: "doc.genre")],
        sortKeys: [FrequencySortKey(.field(0), ascending: true), FrequencySortKey(.count, ascending: false)], minFrequency: 3)

    @Test func everyKindOfAnalysisSurvivesTheJSON() throws {
        let spec = CollocationSpec(attribute: "lemma", measure: .logDice, leftWindow: -3, rightWindow: 4, minFrequency: 5,
                                   minCollocateFrequency: 2, maxItems: 40, anchor: "b")
        var states = [frequency, .collocation(spec), .dispersion]
        states[0].frame = "{{100, 200}, {640, 420}}"
        let data = try JSONEncoder().encode(states)
        let back = try JSONDecoder().decode([AnalysisState].self, from: data)
        #expect(back == states)
        #expect(back[0].fields?.first?.ignoreCase == true)
        #expect(back[0].sortKeys?.last == FrequencySortKey(.count, ascending: false))
        #expect(back[1].collocation?.anchor == "b")
    }

    @Test func aWindowSavedWhereNoScreenIsNowComesBackWithoutAFrame() {
        var state = frequency
        state.frame = "{{40000, 40000}, {600, 400}}"
        #expect(state.visibleFrame == nil)
        state.frame = nil
        #expect(state.visibleFrame == nil)
        let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        state.frame = NSStringFromRect(NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 500, height: 300))
        #expect(state.visibleFrame != nil)
    }

    /// The draft carries what the concordance's window has open, and reading it back keeps them for the window
    /// to open again once the results are in.
    @Test func aConcordanceSavesItsOpenAnalysesAndGivesThemBack() throws {
        let doc = ConcordanceDocument()
        doc.corpusName = "c"
        doc.initialQuery = #"[upos="NOUN"]"#
        doc.analysisStatesProvider = { [frequency] in [frequency, .dispersion] }
        let data = try doc.data(ofType: "cz.cuni.mff.ufal.korpora.concordance")
        #expect(String(decoding: data, as: UTF8.self).contains("\"analyses\""))
        let again = ConcordanceDocument()
        try again.read(from: data, ofType: "cz.cuni.mff.ufal.korpora.concordance")
        #expect(again.restoredAnalyses == [frequency, .dispersion])
    }

    @Test func aDocumentSavedBeforeHasNoAnalysesAndStillOpens() throws {
        let json = #"{"formatVersion":3,"engine":"pando","corpusName":"c","initialQuery":"[]","leftContext":"-5","rightContext":"5","kwicAttr":"form","operations":[]}"#
        let doc = ConcordanceDocument()
        try doc.read(from: Data(json.utf8), ofType: "cz.cuni.mff.ufal.korpora.concordance")
        #expect(doc.restoredAnalyses.isEmpty)
        #expect(doc.initialQuery == "[]")
    }
}

@MainActor @Suite(.serialized) struct ViewStateRestorationTests {
    private let type = "cz.cuni.mff.ufal.korpora.concordance"

    @Test func theSelectedRowAndTheScrollPositionAreSavedAndGivenBack() throws {
        let doc = ConcordanceDocument()
        doc.corpusName = "c"
        doc.initialQuery = "[]"
        doc.viewStateProvider = { .init(selectedRow: 12, topRow: 40) }
        let data = try doc.data(ofType: type)
        let again = ConcordanceDocument()
        try again.read(from: data, ofType: type)
        #expect(again.restoredViewState == .init(selectedRow: 12, topRow: 40))
    }

    @Test func aDocumentSavedBeforeHasNoViewState() throws {
        let json = #"{"formatVersion":3,"engine":"pando","corpusName":"c","initialQuery":"[]","leftContext":"-5","rightContext":"5","kwicAttr":"form","operations":[]}"#
        let doc = ConcordanceDocument()
        try doc.read(from: Data(json.utf8), ofType: type)
        #expect(doc.restoredViewState == nil)
    }

    /// A concordance read in the first seconds of a launch is one the system puts back: it searches when its window
    /// is shown. One read later (File > Open) searches at once.
    @Test func aConcordanceReadAtLaunchWaitsToBeShownAndOneReadLaterDoesNot() throws {
        let json = Data(#"{"formatVersion":3,"engine":"pando","corpusName":"c","initialQuery":"[]","leftContext":"-5","rightContext":"5","kwicAttr":"form","operations":[]}"#.utf8)
        LaunchRestoration.begin()
        let atLaunch = ConcordanceDocument()
        try atLaunch.read(from: json, ofType: type)
        #expect(atLaunch.isReplayDeferred)
        LaunchRestoration.launchWindow = 0
        defer { LaunchRestoration.launchWindow = 4 }
        let later = ConcordanceDocument()
        try later.read(from: json, ofType: type)
        #expect(!later.isReplayDeferred)
    }
}
