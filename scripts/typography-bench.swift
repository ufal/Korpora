// Rendering cost of per-script fonts and a language tag: swiftc -O scripts/typography-bench.swift -o /tmp/bench && /tmp/bench
// (docs/typography.md, "Measured"). Needs Source Han Mono installed for the explicit-font rows.
import AppKit
import CoreText

let latin = "the quick brown fox jumps over a lazy dog while the market is closed".split(separator: " ").map(String.init)
let han = "他说中文很难学但是我觉得有意思因为汉字好看".map(String.init)   // 1-char tokens
let lines = 4000

func run(_ name: String, tokens: [String], makeFont: (String) -> NSFont, lang: String?) {
    let cache = NSCache<NSString, NSFont>()
    _ = cache
    let t0 = CFAbsoluteTimeGetCurrent()
    var width: CGFloat = 0
    for i in 0..<lines {
        let s = NSMutableAttributedString()
        for j in 0..<16 {
            let tok = tokens[(i + j) % tokens.count]
            var a: [NSAttributedString.Key: Any] = [.font: makeFont(tok)]
            if let lang { a[.languageIdentifier] = lang }
            s.append(NSAttributedString(string: tok + " ", attributes: a))
        }
        width += s.size().width            // layout, as the table measures it
    }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(String(format: "%-52@ %7.0f ms  (%5.1f µs/line)", name as NSString, ms, ms * 1000 / Double(lines)))
    if width < 0 { print(width) }
}

let menlo = NSFont(name: "Menlo", size: 12)!
let hanMono = NSFont(name: "SourceHanMono-Regular", size: 16)!
print("\(lines) lines x 16 tokens")
for round in 1...2 {
    print("-- round \(round)")
    run("Latin  Menlo, no language (today)", tokens: latin, makeFont: { _ in menlo }, lang: nil)
    run("Latin  Menlo + language en", tokens: latin, makeFont: { _ in menlo }, lang: "en")
    run("Latin  NSFont(name:) per token (today's override path)", tokens: latin, makeFont: { _ in NSFont(name: "Menlo", size: 12)! }, lang: nil)
    run("Han    Menlo base (system fallback), no language", tokens: han, makeFont: { _ in menlo }, lang: nil)
    run("Han    Menlo base + language zh-Hans", tokens: han, makeFont: { _ in menlo }, lang: "zh-Hans")
    run("Han    explicit Source Han Mono, no language", tokens: han, makeFont: { _ in hanMono }, lang: nil)
    run("Han    explicit Source Han Mono + zh-Hans", tokens: han, makeFont: { _ in hanMono }, lang: "zh-Hans")
    run("Han    NSFont(name:) per token + zh-Hans", tokens: han, makeFont: { _ in NSFont(name: "SourceHanMono-Regular", size: 16)! }, lang: "zh-Hans")
    run("Han    script detect + NSFont(name:) per token + lang", tokens: han, makeFont: { t in
        let s = t.unicodeScalars.first!.value
        return (0x4E00...0x9FFF).contains(s) ? NSFont(name: "SourceHanMono-Regular", size: 16)! : menlo }, lang: "zh-Hans")
}
