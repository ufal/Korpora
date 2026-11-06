// Which glyphs CoreText picks for a language tag: swiftc scripts/typography-glyphs.swift -o /tmp/glyphs && /tmp/glyphs
// (docs/typography.md, "Measured"). Needs the Source Han fonts installed.
import AppKit
import CoreText
let text = "直骨角令刃海返"
func glyphs(_ fontName: String, _ lang: String?) -> (String, [UInt16]) {
    let base = NSFont(name: fontName, size: 16)!
    var attrs: [NSAttributedString.Key: Any] = [.font: base]
    if let lang { attrs[.languageIdentifier] = lang }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    var gl: [UInt16] = []; var names = Set<String>()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let a = CTRunGetAttributes(run) as! [String: Any]
        names.insert(CTFontCopyPostScriptName(a[kCTFontAttributeName as String] as! CTFont) as String)
        var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &g); gl += g
    }
    return (names.sorted().joined(separator: ","), gl)
}
for f in ["SourceHanSans-Regular", "SourceHanSansSC-Regular", "SourceHanSansK-Regular", "SourceHanSerif-Regular", "SourceHanMono-Regular", "Menlo-Regular"] {
    print("== \(f)")
    for lang in [nil, "ja", "zh-Hans", "zh-Hant", "zh-HK", "ko"] as [String?] {
        let (n, g) = glyphs(f, lang)
        print(String(format: "  %-8@", (lang ?? "none") as NSString), n, g.map { String($0) }.joined(separator: " "))
    }
}
