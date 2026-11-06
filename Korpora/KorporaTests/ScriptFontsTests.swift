import AppKit
import Testing
@testable import Korpora

/// The font and size for each script (docs/typography.md): the table, its migration from the old settings, the
/// resolver that makes fonts once, and the neighbour rule for digits and punctuation.
@MainActor @Suite(.serialized) struct ScriptFontsTests {
    private func resolver(_ table: [String: ScriptFont]) -> ScriptFontResolver { ScriptFontResolver(load: { table }) }

    @Test func anEntryIsTheScriptsOwnThenItsGroupsThenOther() {
        let table = ["Han": ScriptFont(name: "A", size: 16), "CJK": ScriptFont(name: "B", size: 15), "Other": ScriptFont(name: "C", size: 13)]
        #expect(ScriptFonts.entry(for: .han, in: table)?.name == "A")
        #expect(ScriptFonts.entry(for: .hangul, in: table)?.name == "B", "the CJK group until a script has its own")
        #expect(ScriptFonts.entry(for: .greek, in: table)?.name == "C")
        #expect(ScriptFonts.entry(for: .greek, in: ["Latin": ScriptFonts.defaultLatin]) == nil, "none: the system fallback")
    }

    @Test func theOldSettingsBecomeTheLatinEntryAndPerScriptFontsKeepTheirSize() {
        let table = ScriptFonts.migrated(resultsFontName: "Courier", resultsFontSize: 14,
                                         overrides: ["greek": "Times-Roman", "cjk": "PingFangSC-Regular", "other": "Helvetica", "bogus": "X"])
        #expect(table["Latin"] == ScriptFont(name: "Courier", size: 14))
        #expect(table["Greek"] == ScriptFont(name: "Times-Roman", size: 14))
        #expect(table["CJK"] == ScriptFont(name: "PingFangSC-Regular", size: 14))
        #expect(table["Other"] == ScriptFont(name: "Helvetica", size: 14))
        #expect(table.count == 4, "an unknown key is dropped")
        #expect(ScriptFonts.migrated(resultsFontName: nil, resultsFontSize: nil, overrides: [:]) == ["Latin": ScriptFonts.defaultLatin])
    }

    @Test func settingsMigrateOnReadAndKeepTheNewTableOnceSaved() {
        let defaults = UserDefaults(suiteName: "ScriptFontsTests-\(UUID().uuidString)")!
        defaults.set("Courier", forKey: "resultsFontName")
        defaults.set(15.0, forKey: "resultsFontSize")
        defaults.set(["cyrillic": "Helvetica"], forKey: "scriptFontOverrides")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.scriptFonts["Latin"] == ScriptFont(name: "Courier", size: 15))
        #expect(settings.scriptFonts["Cyrillic"] == ScriptFont(name: "Helvetica", size: 15))
        settings.scriptFonts = ["Latin": ScriptFont(name: "Menlo-Regular", size: 12)]
        #expect(settings.scriptFonts == ["Latin": ScriptFont(name: "Menlo-Regular", size: 12)], "the old keys no longer count")
    }

    @Test func eachScriptGetsItsOwnFontAtItsOwnSize() throws {
        let fonts = resolver(["Latin": ScriptFont(name: "Menlo-Regular", size: 12), "Han": ScriptFont(name: "Menlo-Regular", size: 16)])
        #expect(fonts.font(for: .latin).font.pointSize == 12)
        #expect(fonts.font(for: .han).font.pointSize == 16)
        #expect(fonts.font(for: .hangul).font.pointSize == 12, "no entry: the Latin size")
    }

    @Test func aFontIsMadeOncePerNameSizeAndStyle() {
        let fonts = resolver(["Latin": ScriptFonts.defaultLatin])
        let first = fonts.font(for: .latin).font, second = fonts.font(for: .latin).font
        #expect(first === second, "the same object, not a new lookup")
        let bold = fonts.font(for: .latin, bold: true).font
        #expect(bold !== first && bold === fonts.font(for: .latin, bold: true).font)
    }

    @Test func changingTheSettingsMakesTheFontsAgain() {
        nonisolated(unsafe) var table = ["Latin": ScriptFont(name: "Menlo-Regular", size: 12)]
        let fonts = ScriptFontResolver(load: { table })
        #expect(fonts.font(for: .latin).font.pointSize == 12)
        table["Latin"] = ScriptFont(name: "Menlo-Regular", size: 18)
        #expect(fonts.font(for: .latin).font.pointSize == 12, "kept until told")
        fonts.reset()
        #expect(fonts.font(for: .latin).font.pointSize == 18)
    }

    @Test func aLanguageTagGoesOnlyOnTheCjkScriptsAndWithAnExplicitFont() {
        let fonts = resolver(["Latin": ScriptFonts.defaultLatin])
        #expect(fonts.font(for: .latin, language: "zh-Hans").language == nil)
        #expect(fonts.font(for: .cyrillic, language: "zh-Hans").language == nil)
        let han = fonts.font(for: .han, sample: "直", language: "zh-Hans")
        #expect(han.language == "zh-Hans")
        #expect(han.font.fontName.contains("PingFang"), "Menlo has no Han: the system's SC font, made explicit: \(han.font.fontName)")
        #expect(fonts.font(for: .han, sample: "骨", language: "zh-Hans").font === han.font, "found once, then cached")
    }

    @Test func theLanguageChoosesTheSystemFontForAScriptWithoutAnEntry() {
        let fonts = resolver(["Latin": ScriptFonts.defaultLatin])
        let japanese = fonts.font(for: .han, sample: "直", language: "ja").font.fontName
        let korean = fonts.font(for: .han, sample: "直", language: "ko").font.fontName
        #expect(japanese.contains("Hiragino"), "\(japanese)")
        #expect(korean.contains("AppleSDGothicNeo"), "\(korean)")
    }

    @Test func aFontThatIsNotInstalledFallsBackInsteadOfBreaking() {
        let fonts = resolver(["Latin": ScriptFonts.defaultLatin, "Han": ScriptFont(name: "NoSuchFont-Regular", size: 16)])
        let font = fonts.font(for: .han, sample: "直").font
        #expect(font.pointSize == 16 && font.fontName != "NoSuchFont-Regular", "the system's font, at the size chosen for Han: \(font)")
    }

    @Test func digitsAndPunctuationTakeTheScriptOfTheWordBefore() {
        func scripts(_ words: [String]) -> [UnicodeScript] {
            KWICCellView.wordScripts(of: words.map { KWICDisplaySegment(text: $0, kind: .word) })
        }
        #expect(scripts(["他", "说", "，", "2025", "年"]) == [.han, .han, .han, .han, .han])
        #expect(scripts(["fox", "，", "быть"]) == [.latin, .latin, .cyrillic])
        #expect(scripts(["(", "быть", ")"]) == [.cyrillic, .cyrillic, .cyrillic], "at the start: the word after it")
        #expect(scripts(["1", "2"]) == [.latin, .latin], "nothing but neutral: Latin")
    }

    @Test func aSecondaryAttributeIsAlwaysLatinAndDoesNotChangeItsNeighbours() {
        let segments = [KWICDisplaySegment(text: "他", kind: .word), KWICDisplaySegment(text: "/PRON", kind: .secondaryAttribute),
                        KWICDisplaySegment(text: "，", kind: .word)]
        #expect(KWICCellView.wordScripts(of: segments) == [.han, .latin, .han])
    }

    @Test func aChineseLineKeepsItsLanguageTagInTheAttributedString() throws {
        let line = KWICCellView.styledText("他 说 中文 ， 2025", bold: false, color: .labelColor)
        #expect(line.string == "他 说 中文 ， 2025")
        var sizes = Set<CGFloat>()
        line.enumerateAttribute(.font, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if let font = value as? NSFont { sizes.insert(font.pointSize) }
        }
        #expect(sizes.count == 1, "the comma and the year follow the Chinese size: \(sizes)")
    }
}
