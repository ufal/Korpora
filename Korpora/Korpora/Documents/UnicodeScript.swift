import Foundation

/// A Unicode script (Latin, Cyrillic, Han, ...), for choosing a font and size per script
/// (docs/typography.md). Detection is a binary search in `UnicodeScriptData`, which is generated from
/// Unicode's `Scripts.txt`, so every script Unicode names is known (177 in Unicode 18).
struct UnicodeScript: Hashable, Sendable {
    /// The name as Unicode writes it: `Latin`, `Han`, `Old_Italic`. This is what the settings store.
    let name: String

    static let latin = UnicodeScript(name: "Latin")
    static let cyrillic = UnicodeScript(name: "Cyrillic")
    static let greek = UnicodeScript(name: "Greek")
    static let hebrew = UnicodeScript(name: "Hebrew")
    static let arabic = UnicodeScript(name: "Arabic")
    static let han = UnicodeScript(name: "Han")
    static let hiragana = UnicodeScript(name: "Hiragana")
    static let katakana = UnicodeScript(name: "Katakana")
    static let hangul = UnicodeScript(name: "Hangul")
    static let bopomofo = UnicodeScript(name: "Bopomofo")
    /// Digits, punctuation, spaces and symbols used by many scripts. Not a writing system.
    static let common = UnicodeScript(name: "Common")
    /// Combining marks, which take the script of the letter they follow. Not a writing system.
    static let inherited = UnicodeScript(name: "Inherited")
    static let unknown = UnicodeScript(name: "Unknown")

    var displayName: String { name.replacingOccurrences(of: "_", with: " ") }

    /// Common, Inherited and Unknown: they say nothing about which font a token needs.
    var isNeutral: Bool { self == .common || self == .inherited || self == .unknown }

    /// The font group a script belongs to: the CJK scripts share one font setting until one of them
    /// is given its own (`ScriptFonts`).
    var group: UnicodeScript? { Self.cjk.contains(self) ? .cjkGroup : nil }
    static let cjkGroup = UnicodeScript(name: "CJK")
    static let cjk: Set<UnicodeScript> = [.han, .hiragana, .katakana, .hangul, .bopomofo]

    /// Every script Unicode names, by name, without the neutral ones.
    static let all: [UnicodeScript] = UnicodeScriptData.names.map(UnicodeScript.init(name:)).filter { !$0.isNeutral }

    /// A letter of the script, for asking the system which font it uses for it: the first of the script's
    /// first range, except for Han, whose first range holds radicals.
    var representative: Unicode.Scalar? {
        if self == .han { return "\u{4E00}" }
        guard let name = UnicodeScriptData.names.firstIndex(of: name) else { return nil }
        guard let range = UnicodeScriptData.scriptIndex.firstIndex(of: UInt16(name)) else { return nil }
        return Unicode.Scalar(UnicodeScriptData.starts[range])
    }

    // MARK: Detection

    /// The script of one code point. Code points outside every range are `.unknown`.
    static func of(_ scalar: Unicode.Scalar) -> UnicodeScript {
        let value = scalar.value
        // Basic Latin letters are the common case.
        if value < 0x80 { return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) ? .latin : .common }
        let starts = UnicodeScriptData.starts
        var low = 0, high = starts.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= value { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard found >= 0, value <= UnicodeScriptData.ends[found] else { return .unknown }
        return UnicodeScript(name: UnicodeScriptData.names[Int(UnicodeScriptData.scriptIndex[found])])
    }

    /// `token`'s script: that of its first scalar that is not neutral, or `.common` for a token made of
    /// digits and punctuation only. Per token, not per character; a token mixing scripts is classified
    /// by whichever comes first.
    static func dominant(in token: String) -> UnicodeScript {
        for scalar in token.unicodeScalars {
            let script = of(scalar)
            if !script.isNeutral { return script }
        }
        return .common
    }
}
