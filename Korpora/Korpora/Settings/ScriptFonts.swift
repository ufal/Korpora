import AppKit
import CoreText

/// A font and a size for one script.
struct ScriptFont: Codable, Equatable, Sendable {
    var name: String
    var size: Double
}

/// The per-script font table (docs/typography.md). Keys are Unicode script names (`Latin`, `Han`), the group
/// key `CJK` (Han, Hiragana, Katakana, Hangul and Bopomofo until one of them has an entry of its own), and
/// `Other` for every script without an entry. There is no global font: Latin is the default entry.
enum ScriptFonts {
    static let otherKey = "Other"
    static let defaultLatin = ScriptFont(name: "Menlo", size: 12)
    static let minimumSize = 6.0
    static let maximumSize = 72.0

    /// The entry for `script`: its own, else its group's, else `Other`. Nil means the system fallback.
    static func entry(for script: UnicodeScript, in table: [String: ScriptFont]) -> ScriptFont? {
        table[script.name] ?? script.group.flatMap { table[$0.name] } ?? table[otherKey]
    }

    /// The Latin entry, which also fixes the size of everything that has no entry.
    static func latin(in table: [String: ScriptFont]) -> ScriptFont { table[UnicodeScript.latin.name] ?? defaultLatin }

    /// What the old settings (one results font and a font name per coarse script) become: the old results
    /// font is the Latin entry, and each old per-script font keeps its name at the Latin size.
    static func migrated(resultsFontName: String?, resultsFontSize: Double?, overrides: [String: String]) -> [String: ScriptFont] {
        let size = (resultsFontSize ?? 0) > 0 ? resultsFontSize! : defaultLatin.size
        var table = [UnicodeScript.latin.name: ScriptFont(name: resultsFontName ?? defaultLatin.name, size: size)]
        let keys = ["latin": "Latin", "cyrillic": "Cyrillic", "greek": "Greek", "hebrew": "Hebrew", "arabic": "Arabic",
                    "cjk": "CJK", "other": otherKey]
        for (old, fontName) in overrides {
            guard let key = keys[old] else { continue }
            table[key] = ScriptFont(name: fontName, size: size)
        }
        return table
    }
}

/// Fonts for the segments of a concordance line. Every segment gets an explicit font (a language tag is only
/// cheap with one: docs/typography.md, "Measured"), and fonts are made once per name and size.
final class ScriptFontResolver: @unchecked Sendable {
    static let shared = ScriptFontResolver()

    private struct Key: Hashable {
        var name: String
        var size: Double
        var bold: Bool
        var script: String
        var language: String
    }

    private let lock = NSLock()
    private var cache: [Key: NSFont] = [:]
    private var table: [String: ScriptFont]?
    private var observer: NSObjectProtocol?
    private let load: @Sendable () -> [String: ScriptFont]

    init(load: @escaping @Sendable () -> [String: ScriptFont] = { AppSettings.shared.scriptFonts }) {
        self.load = load
        observer = NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.reset() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Forgets the table and the fonts (the settings changed).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        table = nil
    }

    private func currentTable() -> [String: ScriptFont] {
        if let table { return table }
        let loaded = load()
        table = loaded
        return loaded
    }

    /// The font for a token of `script` whose text starts with `sample`, and the language tag to put on it
    /// (only the CJK scripts take one). Neutral scripts (digits, punctuation) are drawn as Latin; callers
    /// that know the neighbours pass the neighbour's script instead.
    func font(for script: UnicodeScript, sample: String = "", language: String? = nil, bold: Bool = false)
        -> (font: NSFont, language: String?) {
        lock.lock(); defer { lock.unlock() }
        let script = script.isNeutral ? UnicodeScript.latin : script
        let table = currentTable()
        let tag = UnicodeScript.cjk.contains(script) ? language : nil
        let latin = ScriptFonts.latin(in: table)
        let entry = ScriptFonts.entry(for: script, in: table)
        let size = entry?.size ?? latin.size

        let key = Key(name: entry?.name ?? "", size: size, bold: bold, script: entry == nil ? script.name : "",
                      language: entry == nil ? (tag ?? "") : "")
        if let cached = cache[key] { return (cached, tag) }

        var font: NSFont?
        if let entry { font = NSFont(name: entry.name, size: CGFloat(entry.size)) }
        if font == nil {
            // No entry, or a font that isn't installed: the Latin font, or for another script the font the
            // system would fall back to for it (in the language's form), made explicit once.
            let base = NSFont(name: latin.name, size: CGFloat(size))
                ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
            if script == .latin {
                font = base
            } else {
                let probe = sample.unicodeScalars.first { UnicodeScript.of($0) == script } ?? script.representative
                font = probe.map { Self.fallback(for: base, probe: $0, language: tag) } ?? base
            }
        }
        var result = font!
        if bold { result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask) }
        cache[key] = result
        return (result, tag)
    }

    /// The font CoreText chooses for `sample` when `base` lacks its glyphs.
    private static func fallback(for base: NSFont, probe: Unicode.Scalar, language: String?) -> NSFont {
        let string = String(Character(probe)) as CFString
        let chosen = CTFontCreateForStringWithLanguage(base, string, CFRange(location: 0, length: CFStringGetLength(string)),
                                                       language as CFString?)
        return chosen as NSFont
    }

    /// The tallest line among the fonts of `scripts` (for the row height).
    func lineHeight(forScripts scripts: [UnicodeScript], language: String? = nil) -> CGFloat {
        let fonts = (scripts.isEmpty ? [UnicodeScript.latin] : scripts).map { font(for: $0, language: language).font }
        return fonts.map { ceil($0.ascender - $0.descender + $0.leading) }.max() ?? 0
    }
}
