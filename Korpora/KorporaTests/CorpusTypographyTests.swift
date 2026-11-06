import AppKit
import Testing
@testable import Korpora

/// The row height and language of a corpus's table (docs/typography.md): what the scan of the word list finds, what
/// the user typed, and the global override.
@MainActor @Suite(.serialized) struct CorpusTypographyTests {
    private func freshSettings() -> AppSettings { AppSettings(defaults: UserDefaults(suiteName: "CorpusTypographyTests-\(UUID().uuidString)")!) }

    private func resolver() -> ScriptFontResolver {
        ScriptFontResolver(load: { ["Latin": ScriptFont(name: "Menlo-Regular", size: 12), "CJK": ScriptFont(name: "Menlo-Regular", size: 16)] })
    }

    /// A corpus folder with a word list (`form.lex`): the forms, each ended by a NUL.
    private func corpus(forms: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        for form in forms { data.append(Data(form.utf8)); data.append(0) }
        try data.write(to: directory.appendingPathComponent("form.lex"))
        return directory
    }

    // MARK: The scan

    @Test func theScanCountsDistinctFormsPerScript() throws {
        let directory = try corpus(forms: ["the", "fox", "быть", "世界", "你好", "12", ",", "ひらがな"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let scan = try #require(CorpusScriptScan.scan(corpusDirectory: directory, attribute: "form", tokens: 8))
        #expect(scan.formsByScript == ["Latin": 2, "Cyrillic": 1, "Han": 2, "Hiragana": 1], "digits and punctuation count for no script")
        #expect(scan.tokens == 8)
    }

    @Test func aMissingOrEmptyWordListGivesNoScan() throws {
        #expect(CorpusScriptScan.scan(corpusDirectory: URL(fileURLWithPath: "/nonexistent"), attribute: "form", tokens: 1) == nil)
        let directory = try corpus(forms: ["12", "!"])
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(CorpusScriptScan.scan(corpusDirectory: directory, attribute: "form", tokens: 1) == nil, "nothing but neutral forms")
    }

    @Test func aBrokenByteDoesNotStopTheScan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = Data([0xFF, 0xFE, 0]); data.append(Data("fox".utf8)); data.append(0)
        try data.write(to: directory.appendingPathComponent("form.lex"))
        let scan = try #require(CorpusScriptScan.scan(corpusDirectory: directory, attribute: "form", tokens: 1))
        #expect(scan.formsByScript["Latin"] == 1)
    }

    @Test func aScriptSetsTheRowHeightOnlyAboveTheThreshold() {
        // 1 of 1,000 forms is 0.1%: below 0.2%.
        let few = CorpusTypography.Scan(tokens: 1, formsByScript: ["Latin": 999, "Han": 1], language: nil)
        #expect(CorpusTypographyRules.significantScripts(few) == [.latin])
        let many = CorpusTypography.Scan(tokens: 1, formsByScript: ["Latin": 900, "Han": 100], language: nil)
        #expect(CorpusTypographyRules.significantScripts(many) == [.han, .latin])
    }

    // MARK: Language

    @Test func kanaMeanJapaneseAndHangulKoreanBothMeanMixed() {
        func language(_ counts: [String: Int], _ sample: String = "") -> String? { CorpusTypographyRules.language(formsByScript: counts, hanSample: sample) }
        #expect(language(["Latin": 500, "Han": 400, "Hiragana": 100]) == "ja")
        #expect(language(["Latin": 500, "Hangul": 400, "Han": 5]) == "ko")
        #expect(language(["Hiragana": 100, "Hangul": 100, "Han": 100]) == nil, "a corpus of several languages")
        #expect(language(["Latin": 1000]) == nil)
        #expect(language(["Han": 100]) == nil, "no sample to tell Simplified from Traditional")
    }

    @Test func hanAloneIsToldSimplifiedFromTraditional() {
        let simplified = "这个问题很难说明白我们应该学习汉语因为语言对于国际交流非常重要"
        let traditional = "這個問題很難說明白我們應該學習漢語因為語言對於國際交流非常重要"
        #expect(CorpusTypographyRules.language(formsByScript: ["Han": 100], hanSample: simplified) == "zh-Hans")
        #expect(CorpusTypographyRules.language(formsByScript: ["Han": 100], hanSample: traditional) == "zh-Hant")
    }

    @Test func aTypedLanguageIsTidied() {
        #expect(CorpusTypographyRules.normalizedLanguage("zh_hans") == "zh-Hans")
        #expect(CorpusTypographyRules.normalizedLanguage(" ZH-hk ") == "zh-HK")
        #expect(CorpusTypographyRules.normalizedLanguage("ja") == "ja")
        #expect(CorpusTypographyRules.normalizedLanguage("auto") == nil)
        #expect(CorpusTypographyRules.normalizedLanguage("  ") == nil)
    }

    // MARK: The row height

    @Test func aLatinCorpusKeepsTheDefaultRowHeightAndACjkOneGetsMore() {
        let latin = CorpusTypography(scan: .init(tokens: 1, formsByScript: ["Latin": 100], language: nil))
        let chinese = CorpusTypography(scan: .init(tokens: 1, formsByScript: ["Latin": 80, "Han": 20], language: "zh-Hans"))
        let fonts = resolver()
        #expect(CorpusTypographyService.automaticRowHeight(for: latin, fonts: fonts) == CorpusTypographyRules.defaultRowHeight)
        let tall = CorpusTypographyService.automaticRowHeight(for: chinese, fonts: fonts)
        #expect((tall ?? 0) > CorpusTypographyRules.defaultRowHeight, "16 pt CJK needs a taller row: \(String(describing: tall))")
        #expect(CorpusTypographyService.automaticRowHeight(for: CorpusTypography(), fonts: fonts) == nil, "no scan yet")
    }

    @Test func theEffectiveValuesAreTypedThenGlobalThenScanned() async throws {
        let directory = try corpus(forms: ["他", "说", "中文", "the"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = freshSettings()
        let fonts = resolver()
        let scanned = await CorpusTypographyService.effective(corpus: "zh", directory: directory, attribute: "form", tokens: 4, settings: settings, fonts: fonts)
        #expect(scanned.rowHeight > CorpusTypographyRules.defaultRowHeight, "from the scan")
        #expect(settings.typography(for: "zh").scan?.tokens == 4, "which is kept")

        settings.globalRowHeight = 40
        let global = await CorpusTypographyService.effective(corpus: "zh", directory: directory, attribute: "form", tokens: 4, settings: settings, fonts: fonts)
        #expect(global.rowHeight == 40, "the global one replaces the scanned")

        settings.updateTypography(for: "zh") { $0.rowHeight = 30; $0.language = "ja" }
        let typed = await CorpusTypographyService.effective(corpus: "zh", directory: directory, attribute: "form", tokens: 4, settings: settings, fonts: fonts)
        #expect(typed == EffectiveTypography(rowHeight: 30, language: "ja"), "what is typed for the corpus wins")
    }

    @Test func theScanDoesNotRunWhenEverythingIsTypedOrItIsKept() async throws {
        let directory = try corpus(forms: ["中文"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = freshSettings()
        settings.updateTypography(for: "c") { $0.rowHeight = 30; $0.language = "zh-Hans" }
        _ = await CorpusTypographyService.effective(corpus: "c", directory: directory, attribute: "form", tokens: 1, settings: settings, fonts: resolver())
        #expect(settings.typography(for: "c").scan == nil, "height and language are typed: nothing to find out")

        settings.updateTypography(for: "c") { $0.rowHeight = nil }
        _ = await CorpusTypographyService.effective(corpus: "c", directory: directory, attribute: "form", tokens: 1, settings: settings, fonts: resolver())
        #expect(settings.typography(for: "c").scan != nil)
        try? FileManager.default.removeItem(at: directory)
        let again = await CorpusTypographyService.effective(corpus: "c", directory: directory, attribute: "form", tokens: 1, settings: settings, fonts: resolver())
        #expect(again.rowHeight > CorpusTypographyRules.defaultRowHeight, "the kept scan is used while the corpus has the same size")
    }

    @Test func aCorpusWithoutAFolderStaysAtTheStandardValues() async {
        let settings = freshSettings()
        let result = await CorpusTypographyService.effective(corpus: "fake", directory: nil, attribute: "form", tokens: 10, settings: settings, fonts: resolver())
        #expect(result == .standard)
    }

    @Test func renamingAndForgettingFollowTheCorpus() {
        let settings = freshSettings()
        settings.updateTypography(for: "a") { $0.rowHeight = 30 }
        settings.renameTypography(from: "a", to: "b")
        #expect(settings.typography(for: "a") == CorpusTypography() && settings.typography(for: "b").rowHeight == 30)
        settings.forgetTypography(for: "b")
        #expect(settings.corpusTypography.isEmpty)
        settings.updateTypography(for: "x") { $0.rowHeight = nil }
        #expect(settings.corpusTypography.isEmpty, "an entry with nothing in it is not kept")
    }

    @Test func theGlobalRowHeightIsOffUntilSetAndRemembersItsValue() {
        let settings = freshSettings()
        #expect(settings.globalRowHeight == nil && settings.lastGlobalRowHeight == CorpusTypographyRules.defaultRowHeight)
        settings.globalRowHeight = 36
        #expect(settings.globalRowHeight == 36)
        settings.globalRowHeight = nil
        #expect(settings.globalRowHeight == nil && settings.lastGlobalRowHeight == 36)
    }
}
