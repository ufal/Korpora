import Foundation
import XCTest
@testable import KorporaEngine

/// Regular expressions in queries read text, not bytes. pando built without RE2 reads a pattern as bytes:
/// `.` is one byte, and `[無非毋不沒莫]` is a set of single bytes, which also matches 你 or 搵 (they share a
/// byte with a character in the class). So `[form="[無非毋不沒莫]+.+"]` found words without any of them, and
/// "four characters" had to be written as eight dots for Cyrillic and twelve for Chinese. These tests fail
/// on such a build (scripts/pando-spike.sh builds pando with RE2, as does the release build).
final class UnicodeRegexTests: XCTestCase {
    /// One sentence; every token hangs on the first. Words chosen so that wrong (byte) readings show:
    /// 你 and 搵 share their first byte with 不 and 沒; 'па' (Cyrillic) is two bytes, 'γε' (Greek) too.
    private static let words = [
        "不如", "無綫", "沒有", "莫非", "非常", "毋庸",       // negation character first
        "你", "搵", "喺度", "好嘅", "我哋",                    // Chinese without any of the six
        "па", "Сара", "сан", "слово", "γε", "Ελλάδα",         // Cyrillic, Greek
        "cat", "Cat", "naïve", "x",                            // Latin
    ]

    private static var conllu: String {
        var lines = ["# sent_id = u1"]
        for (i, word) in words.enumerated() {
            let id = i + 1
            lines.append("\(id)\t\(word)\t\(word)\tX\t_\t_\t\(id == 1 ? 0 : 1)\t\(id == 1 ? "root" : "dep")\t_\t_")
        }
        return lines.joined(separator: "\n") + "\n\n\n"
    }

    /// The matched forms of `query`, in text order.
    private func matches(_ query: String) async throws -> [String] {
        let box = try TestPando.Sandbox()
        let engine = try await TestPando.buildCorpus("Unicode", conllu: Self.conllu, in: box)
        let corpus = try await engine.openCorpus(name: "Unicode")
        let live = try await engine.openConcordance(query: query, in: corpus)
        let size = await live.size
        guard size > 0 else { return [] }
        let lines = try await live.kwicLines(range: 0..<size, leftContext: "0", rightContext: "0", kwicAttr: "form",
                                             secondaryAttributes: [])
        return lines.flatMap { $0.kwicTokens.filter(\.isMatch).map(\.word) }
    }

    /// The report's own query: words that start with a negation character, and only those.
    func testACharacterClassOfChineseCharactersMatchesThoseCharacters() async throws {
        let found = try await matches(#"[form="[無非毋不沒莫]+.+"]"#)
        XCTAssertEqual(found, ["不如", "無綫", "沒有", "莫非", "非常", "毋庸"])
    }

    func testANegatedClassOfChineseCharactersExcludesWholeCharacters() async throws {
        let found = try await matches(#"[form="[^無非毋不沒莫].*" & form="\p{Han}+"]"#)
        XCTAssertEqual(found, ["你", "搵", "喺度", "好嘅", "我哋"])
    }

    /// `.` is one character: two characters are two dots whatever the script.
    func testADotIsOneCharacterInEveryScript() async throws {
        let two = try await matches(#"[form=".."]"#)
        XCTAssertEqual(two, ["不如", "無綫", "沒有", "莫非", "非常", "毋庸", "喺度", "好嘅", "我哋", "па", "γε"])
        let four = try await matches(#"[form="...."]"#)
        XCTAssertEqual(four, ["Сара"])
        let five = try await matches(#"[form="....."]"#)
        XCTAssertEqual(five, ["слово", "naïve"])
        let one = try await matches(#"[form="."]"#)
        XCTAssertEqual(one, ["你", "搵", "x"])
    }

    func testRepeatCountsCountCharacters() async throws {
        let found = try await matches(#"[form=".{2}" & form="\p{Han}+"]"#)
        XCTAssertEqual(found, ["不如", "無綫", "沒有", "莫非", "非常", "毋庸", "喺度", "好嘅", "我哋"])
    }

    func testUnicodePropertiesWork() async throws {
        let han = try await matches(#"[form="\p{Han}+"]"#)
        XCTAssertEqual(han.count, 11)
        XCTAssertTrue(han.allSatisfy { $0.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } })
        let cyrillic = try await matches(#"[form="\p{Cyrillic}+"]"#)
        XCTAssertEqual(cyrillic, ["па", "Сара", "сан", "слово"])
        let greek = try await matches(#"[form="\p{Greek}+"]"#)
        XCTAssertEqual(greek, ["γε", "Ελλάδα"])
        let upper = try await matches(#"[form="\p{Lu}.*"]"#)
        XCTAssertEqual(upper, ["Сара", "Ελλάδα", "Cat"])
    }

    func testRangesOfNonAsciiLettersAreCharacterRanges() async throws {
        let found = try await matches(#"[form="[а-я]+"]"#)
        XCTAssertEqual(found, ["па", "сан", "слово"])
    }

    func testCaseInsensitiveMatchingKnowsNonLatinLetters() async throws {
        let found = try await matches(#"[form="(?i)сара"]"#)
        XCTAssertEqual(found, ["Сара"])
        let latin = try await matches(#"[form="(?i)cat"]"#)
        XCTAssertEqual(latin, ["cat", "Cat"])
    }

    /// A pattern in the slashed form `= /…/` is the same engine.
    func testTheSlashedFormReadsCharactersToo() async throws {
        let found = try await matches(#"[form = /[無非毋不沒莫].+/]"#)
        XCTAssertEqual(found, ["不如", "無綫", "沒有", "莫非", "非常", "毋庸"])
    }
}
