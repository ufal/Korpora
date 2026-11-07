import Foundation
import KorporaEngine
import NaturalLanguage

/// What the app keeps about the typography of one corpus (docs/typography.md): a row height and a language the
/// user typed (nil: automatic), and what the last scan of the corpus's word list found.
struct CorpusTypography: Codable, Equatable, Sendable {
    var rowHeight: Double?
    /// A BCP-47 code (`zh-Hans`, `ja`, ...) typed by the user; nil is automatic.
    var language: String?
    var scan: Scan?

    struct Scan: Codable, Equatable, Sendable {
        /// The corpus's size in tokens when it was scanned: a different size means a new scan.
        var tokens: Int
        /// Distinct word forms per script (a form counts for the script of its first letter).
        var formsByScript: [String: Int]
        /// What the scan made of the language, nil when it can't tell (or the corpus mixes several).
        var language: String?
    }
}

extension AppSettings {
    /// Typography per corpus name. A rename moves the entry, a removal drops it.
    var corpusTypography: [String: CorpusTypography] {
        get {
            defaults.data(forKey: "corpusTypography").flatMap { try? JSONDecoder().decode([String: CorpusTypography].self, from: $0) } ?? [:]
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: "corpusTypography")
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    func typography(for corpus: String) -> CorpusTypography { corpusTypography[corpus] ?? CorpusTypography() }

    func updateTypography(for corpus: String, _ change: (inout CorpusTypography) -> Void) {
        var all = corpusTypography
        var entry = all[corpus] ?? CorpusTypography()
        change(&entry)
        all[corpus] = entry == CorpusTypography() ? nil : entry
        corpusTypography = all
    }

    func renameTypography(from old: String, to new: String) {
        var all = corpusTypography
        guard let entry = all.removeValue(forKey: old) else { return }
        all[new] = entry
        corpusTypography = all
    }

    func forgetTypography(for corpus: String) {
        var all = corpusTypography
        guard all.removeValue(forKey: corpus) != nil else { return }
        corpusTypography = all
    }

    /// One row height for every corpus, replacing the per-corpus and detected ones (nil: off).
    var globalRowHeight: Double? {
        get { defaults.bool(forKey: "useGlobalRowHeight") ? max(defaults.double(forKey: "globalRowHeight"), CorpusTypographyRules.minimumRowHeight) : nil }
        set {
            defaults.set(newValue != nil, forKey: "useGlobalRowHeight")
            if let newValue { defaults.set(newValue, forKey: "globalRowHeight") }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The last number typed for the global row height, whether it is on or not.
    var lastGlobalRowHeight: Double {
        let value = defaults.double(forKey: "globalRowHeight")
        return value > 0 ? value : CorpusTypographyRules.defaultRowHeight
    }
}

enum CorpusTypographyRules {
    /// The table's own default row height, which every Latin-only corpus keeps.
    static let defaultRowHeight = 24.0
    static let minimumRowHeight = 12.0
    static let maximumRowHeight = 200.0
    /// A script that is less than this share of the corpus's distinct word forms does not set the row height.
    static let scriptThreshold = 0.002

    /// The row height that fits a line of `lineHeight` points: the line plus room, never below the default.
    static func rowHeight(forLine lineHeight: Double) -> Double { max(defaultRowHeight, lineHeight + 8) }

    /// The scripts that make up at least `scriptThreshold` of the scan's forms.
    static func significantScripts(_ scan: CorpusTypography.Scan) -> [UnicodeScript] {
        let total = scan.formsByScript.values.reduce(0, +)
        guard total > 0 else { return [] }
        return scan.formsByScript.filter { Double($0.value) / Double(total) >= scriptThreshold }.keys.sorted().map(UnicodeScript.init(name:))
    }

    /// A language code the user typed, tidied (`zh_hans` and `zh-hans` both become `zh-Hans`); nil for empty or `auto`.
    static func normalizedLanguage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        let parts = trimmed.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        return parts.enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 4 { return part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            return part.uppercased()
        }.joined(separator: "-")
    }

    /// The language of the CJK text in a corpus: kana mean Japanese, Hangul Korean, both (a corpus of several
    /// languages) nothing; Han alone is told Simplified from Traditional by `NLLanguageRecognizer` on a sample.
    static func language(formsByScript: [String: Int], hanSample: String) -> String? {
        let total = formsByScript.values.reduce(0, +)
        guard total > 0 else { return nil }
        func has(_ script: UnicodeScript) -> Bool { Double(formsByScript[script.name] ?? 0) / Double(total) >= scriptThreshold }
        let kana = has(.hiragana) || has(.katakana), hangul = has(.hangul)
        if kana && hangul { return nil }
        if kana { return "ja" }
        if hangul { return "ko" }
        guard has(.han), !hanSample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(hanSample)
        let best = recognizer.languageHypotheses(withMaximum: 1).first
        guard let best, best.value >= 0.6 else { return nil }
        return best.key == .traditionalChinese ? "zh-Hant" : "zh-Hans"
    }
}

/// Reads a corpus's list of distinct word forms (`<attribute>.lex`: UTF-8 strings, each ended by a NUL) and counts
/// the scripts. Reading is by pando's file layout, not an API: when the file isn't there or doesn't parse, the
/// answer is nil and the row height stays at the default.
enum CorpusScriptScan {
    static func scan(corpusDirectory: URL, attribute: String, tokens: Int) -> CorpusTypography.Scan? {
        let url = corpusDirectory.appendingPathComponent("\(attribute).lex")
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        var hanSample: [String] = []
        var hanSeen = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            let end = bytes.count
            while index < end {
                // One form: find its script by its first letter, then skip to its end.
                let start = index
                var script: UnicodeScript = .common
                while index < end, bytes[index] != 0 {
                    let (scalar, length) = decode(bytes, at: index, end: end)
                    index += length
                    let found = UnicodeScript.of(scalar)
                    if !found.isNeutral { script = found; break }
                }
                while index < end, bytes[index] != 0 { index += 1 }
                if script != .common {
                    counts[script.name, default: 0] += 1
                    if script == .han {
                        hanSeen += 1
                        if hanSeen % 50 == 0, hanSample.count < 400 {
                            hanSample.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self))
                        }
                    }
                }
                index += 1  // the NUL
            }
        }
        guard !counts.isEmpty else { return nil }
        return CorpusTypography.Scan(
            tokens: tokens, formsByScript: counts,
            language: CorpusTypographyRules.language(formsByScript: counts, hanSample: hanSample.joined()))
    }

    /// The scalar at `index` and its length in bytes; a broken sequence counts as one byte of U+FFFD.
    private static func decode(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int, end: Int) -> (Unicode.Scalar, Int) {
        let first = UInt32(bytes[index])
        func continuation(_ offset: Int) -> UInt32? {
            index + offset < end && bytes[index + offset] & 0xC0 == 0x80 ? UInt32(bytes[index + offset] & 0x3F) : nil
        }
        if first < 0x80 { return (Unicode.Scalar(first)!, 1) }
        if first >= 0xC2, first < 0xE0, let b = continuation(1) { return (Unicode.Scalar(((first & 0x1F) << 6) | b) ?? "\u{FFFD}", 2) }
        if first >= 0xE0, first < 0xF0, let b = continuation(1), let c = continuation(2) {
            return (Unicode.Scalar(((first & 0x0F) << 12) | (b << 6) | c) ?? "\u{FFFD}", 3)
        }
        if first >= 0xF0, first < 0xF5, let b = continuation(1), let c = continuation(2), let d = continuation(3) {
            return (Unicode.Scalar(((first & 0x07) << 18) | (b << 12) | (c << 6) | d) ?? "\u{FFFD}", 4)
        }
        return ("\u{FFFD}", 1)
    }
}

/// What a concordance window needs to know about its corpus's typography.
struct EffectiveTypography: Equatable, Sendable {
    var rowHeight: Double
    var language: String?
    /// The corpus has CJK text in more than one language and no language was typed: every line is told its own
    /// (`LineLanguage`).
    var perLineLanguage = false
    static let standard = EffectiveTypography(rowHeight: CorpusTypographyRules.defaultRowHeight, language: nil)
}

/// The language of one line of a corpus that mixes several: kana mean Japanese, Hangul Korean, and Han alone is
/// told Simplified from Traditional by `NLLanguageRecognizer` (about 40 µs a line), when it is sure.
enum LineLanguage {
    /// UD treebanks whose language needs more than the code: `zh` is Traditional in most treebanks, but the
    /// simplified-characters edition of GSD is `zh_gsdsimp`, and the two Hong Kong treebanks (Chinese and Cantonese)
    /// are written in Traditional characters in Hong Kong's glyph forms. Keys are `<code>_<treebank>`, as UD names
    /// its files.
    static let treebankLanguages = ["zh_gsdsimp": "zh-Hans", "zh_hk": "zh-HK", "yue_hk": "zh-HK"]

    /// The region attribute that holds the treebank of a line (UD: `text.treebank`), when the corpus has one.
    static func treebankAttribute(in structures: [StructureInfo]) -> String? {
        structures.contains { $0.name == "text" && $0.attributes.contains("treebank") } ? "text.treebank" : nil
    }

    /// The region attribute that holds a language, first of these that the corpus has.
    static func languageAttribute(in structures: [StructureInfo]) -> String? {
        for candidate in ["text.langcode", "doc.langcode", "text.lang", "doc.lang"] {
            let parts = candidate.split(separator: ".").map(String.init)
            if structures.contains(where: { $0.name == parts[0] && $0.attributes.contains(parts[1]) }) { return candidate }
        }
        return nil
    }

    /// The tag for a line the corpus calls `code` (a UD language code: `ja`, `ko`, `zh`, `lzh`, `yue`, ...): the
    /// code decides for Japanese and Korean, Classical Chinese is Traditional and Cantonese is Hong Kong; `zh` does
    /// not say Simplified or Traditional, so the text does. With no code (or `_`) the text decides.
    static func language(forCode code: String?, treebank: String? = nil, in line: KWICLine) -> String? {
        let code = code?.lowercased()
        if let code, let treebank, let known = treebankLanguages["\(code)_\(treebank.lowercased())"] { return known }
        switch code {
        case nil, "", "_": return detect(in: line)
        case "ja"?, "ko"?: return code
        case "lzh"?: return "zh-Hant"
        case "yue"?:
            // Cantonese is written in Hong Kong in Traditional characters, in Hong Kong's forms; text in Simplified
            // characters (as written for Mainland readers) takes the Simplified forms.
            return detect(in: line) == "zh-Hans" ? "zh-Hans" : "zh-HK"
        case "zh"?, "cmn"?: return detect(in: line)
        default: return nil  // not a CJK language: no tag
        }
    }

    static func detect(in line: KWICLine) -> String? {
        var text = ""
        for token in line.leftTokens + line.kwicTokens + line.rightTokens { text += token.word }
        return detect(in: text)
    }

    static func detect(in text: String) -> String? {
        var han = false
        for scalar in text.unicodeScalars where scalar.value >= 0x2E80 {
            switch UnicodeScript.of(scalar) {
            case .hiragana, .katakana: return "ja"
            case .hangul: return "ko"
            case .han: han = true
            default: break
            }
        }
        guard han else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.7 else { return nil }
        return best.key == .traditionalChinese ? "zh-Hant" : "zh-Hans"
    }
}

enum CorpusTypographyService {
    /// The row height worked out from a corpus's scan, for showing as the automatic value; nil without a scan.
    static func automaticRowHeight(for typography: CorpusTypography, fonts: ScriptFontResolver = .shared) -> Double? {
        guard let scan = typography.scan else { return nil }
        let language = typography.language ?? scan.language
        let line = fonts.lineHeight(forScripts: CorpusTypographyRules.significantScripts(scan), language: language)
        return CorpusTypographyRules.rowHeight(forLine: Double(line))
    }

    /// The row height and language for `corpus`: what the user typed, else the global row height (height only),
    /// else what the scan found. The scan runs (and is kept) only when something is automatic and the stored one
    /// is missing or for another size of corpus.
    static func effective(
        corpus: String, directory: URL?, attribute: String, tokens: Int, settings: AppSettings,
        fonts: ScriptFontResolver = .shared
    ) async -> EffectiveTypography {
        let stored = settings.typography(for: corpus)
        let heightIsAutomatic = stored.rowHeight == nil && settings.globalRowHeight == nil
        let languageIsAutomatic = stored.language == nil
        var scan = stored.scan
        if (heightIsAutomatic || languageIsAutomatic), scan?.tokens != tokens, let directory {
            let found = await Task.detached(priority: .utility) {
                CorpusScriptScan.scan(corpusDirectory: directory, attribute: attribute, tokens: tokens)
            }.value
            if let found {
                scan = found
                await MainActor.run { settings.updateTypography(for: corpus) { $0.scan = found } }
            }
        }
        let language = stored.language ?? scan?.language
        let height: Double
        if let manual = stored.rowHeight ?? settings.globalRowHeight {
            height = manual
        } else if let scan, let automatic = automaticRowHeight(
            for: CorpusTypography(rowHeight: nil, language: stored.language, scan: scan), fonts: fonts) {
            height = automatic
        } else {
            height = CorpusTypographyRules.defaultRowHeight
        }
        // Several languages in the corpus: a CJK script is there, but no single language came out of it.
        let hasCJK = scan.map { s in CorpusTypographyRules.significantScripts(s).contains { UnicodeScript.cjk.contains($0) } } ?? false
        return EffectiveTypography(rowHeight: min(max(height, CorpusTypographyRules.minimumRowHeight), CorpusTypographyRules.maximumRowHeight),
                                   language: language, perLineLanguage: language == nil && hasCJK)
    }
}
