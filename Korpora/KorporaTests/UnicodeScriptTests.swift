import Testing
@testable import Korpora

@Suite struct UnicodeScriptTests {
    @Test func dominantClassifiesEachCoveredScript() {
        #expect(UnicodeScript.dominant(in: "fox") == .latin)
        #expect(UnicodeScript.dominant(in: "Über") == .latin)
        #expect(UnicodeScript.dominant(in: "быть") == .cyrillic)
        #expect(UnicodeScript.dominant(in: "λόγος") == .greek)
        #expect(UnicodeScript.dominant(in: "שלום") == .hebrew)
        #expect(UnicodeScript.dominant(in: "مرحبا") == .arabic)
        #expect(UnicodeScript.dominant(in: "日本語") == .han)
    }

    @Test func theCjkScriptsAreToldApart() {
        #expect(UnicodeScript.dominant(in: "中文") == .han)
        #expect(UnicodeScript.dominant(in: "ひらがな") == .hiragana)
        #expect(UnicodeScript.dominant(in: "カタカナ") == .katakana)
        #expect(UnicodeScript.dominant(in: "한국어") == .hangul)
        #expect(UnicodeScript.dominant(in: "ㄅㄆㄇ") == .bopomofo)
        #expect(UnicodeScript.han.group == .cjkGroup && UnicodeScript.hangul.group == .cjkGroup)
        #expect(UnicodeScript.latin.group == nil)
    }

    @Test func scriptsFarFromTheHandWrittenOnesAreKnownToo() {
        #expect(UnicodeScript.dominant(in: "ᚠᚢᚦ").name == "Runic")
        #expect(UnicodeScript.dominant(in: "ᚁᚂᚃ").name == "Ogham")
        #expect(UnicodeScript.dominant(in: "ಕನ್ನಡ").name == "Kannada")
        #expect(UnicodeScript.dominant(in: "ไทย").name == "Thai")
        #expect(UnicodeScript.dominant(in: "𓀀").name == "Egyptian_Hieroglyphs")
        #expect(UnicodeScript.dominant(in: "ⴰⵣⵓⵍ").name == "Tifinagh")
    }

    @Test func everyScriptUnicodeNamesIsOffered() {
        #expect(UnicodeScript.all.count >= 170, "Unicode 18 names 177, less Common and Inherited")
        #expect(UnicodeScript.all.contains(.latin) && UnicodeScript.all.contains(.han))
        #expect(!UnicodeScript.all.contains(.common) && !UnicodeScript.all.contains(.inherited))
        #expect(UnicodeScript.all.allSatisfy { $0.representative != nil }, "each has a letter to ask the system about")
        #expect(UnicodeScript.of(UnicodeScript.han.representative!) == .han)
    }

    @Test func dominantFallsBackToCommonForDigitsPunctuationAndSpaces() {
        #expect(UnicodeScript.dominant(in: "123") == .common)
        #expect(UnicodeScript.dominant(in: "!?") == .common)
        #expect(UnicodeScript.dominant(in: " ") == .common)
        #expect(UnicodeScript.dominant(in: "") == .common)
        #expect(UnicodeScript.dominant(in: "\u{FF0C}") == .common, "the fullwidth comma")
    }

    @Test func dominantUsesTheFirstNonNeutralScalarInAMixedToken() {
        // "123fox" - digits first, but "fox" is what actually determines a real font choice.
        #expect(UnicodeScript.dominant(in: "123fox") == .latin)
        #expect(UnicodeScript.dominant(in: "123быть") == .cyrillic)
    }
}
