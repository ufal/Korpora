# Typography: a font and size per script, and a language per corpus (design, 2026-11-07)

Status: designed and measured; not built yet. This page is the record of why it is the way it is.

## The problem

A concordance mixes scripts. The UD corpus has 37 of them in its word list; a Korean or Chinese corpus has Latin
words, numbers and punctuation inside the native text. Today Korpora has one global font and size and seven
hard-coded script ranges (`UnicodeScript`: Latin, Cyrillic, Greek, Hebrew, Arabic, "CJK", other) with an optional
font per script, but no size per script. This causes three problems:

1. The global font and the Latin entry clash: what if a Latin font is set as well?
2. A size that suits Latin (12 pt) is too small for Chinese (16 pt); a font that suits one script may not suit
   another.
3. Han characters have different glyph shapes in Simplified Chinese, Traditional Chinese (Taiwan, Hong Kong),
   Japanese and Korean. macOS picks one by the user's language preferences, which is not the language of the
   corpus.

## What macOS gives us

- **Language tag.** `NSAttributedString.Key.languageIdentifier` (macOS 12+; CoreText's `kCTLanguageAttributeName`)
  takes a BCP-47 code. CoreText uses it to pick localised glyph forms (the OpenType `locl` feature) where the font
  has them, and to choose the fallback font when the font lacks a glyph.
- **Font fallback.** If the font has no glyph, macOS chooses another font for the character.
- **Unicode data.** Unicode's `Scripts.txt` (18.0 draft) names 177 scripts (175 writing systems plus Common and
  Inherited) in about 2,300 ranges. It can be turned into a Swift table with a binary search.
- **`NLLanguageRecognizer`** (NaturalLanguage framework) tells Simplified from Traditional Chinese, Japanese and
  Korean from a sample of text, on the device.

## Measured

Scripts: `scripts/typography-glyphs.swift` and `scripts/typography-bench.swift`. macOS 27, Apple Silicon.

**The language tag changes the glyphs.** The string 直骨角令刃海返 in Menlo 16 pt (which has no Han glyphs) falls back to
different system fonts depending on the tag:

| tag | font used |
|---|---|
| none | PingFang TC (from this Mac's language preferences) |
| `zh-Hans` | PingFang SC |
| `zh-Hant` | PingFang TC |
| `zh-HK` | PingFang HK |
| `ja` | Hiragino Sans |
| `ko` | Apple SD Gothic Neo |

With Source Han Sans, Serif and Mono (all regions in one family, and the regional SC, TC, HC and K families) the
glyph numbers change with the tag for every font. In a regional family the tag overrides the family's default
region (Source Han Sans SC with `ja` gives the Japanese glyphs). Without a tag the all-regions family shows the
Japanese forms. So one family plus a language is enough, and a Chinese corpus without a tag would show Japanese
shapes in it. (Glyph numbers prove different glyphs are chosen, not how they look.)

**Cost.** 4,000 lines of 16 tokens, an attributed string built and laid out with `size()`:

| case | µs per line |
|---|---:|
| Latin, Menlo, no language (today) | 13 to 18 |
| Latin, Menlo, language `en` | 18 |
| Latin, `NSFont(name:)` called per token (today's per-script path) | 38 |
| Han, Menlo as base font (system fallback), no language (today) | 38 |
| **Han, Menlo as base font, language `zh-Hans`** | **713** |
| Han, Source Han Mono set explicitly | 16 |
| Han, Source Han Mono set explicitly, language `zh-Hans` | 23 |
| Han, font looked up per token, language `zh-Hans` | 28 |

A language tag with the fallback is about 20 times slower, because CoreText builds the language's font cascade
for every string. A language tag with an explicit font costs 7 µs per line. Looking up `NSFont(name:size:)` per
token doubles the cost. At 20 to 40 µs per line a screen of 50 rows takes 1 to 2 ms. Drawing and wrapping are not
measured (the table truncates).

## Design

**Rules that follow from the measurements**
1. Every segment gets an explicit font. A language is set only together with an explicit font.
2. Fonts are created once per (name, size) and cached.
3. For a script without a configured font, the system's font for that script and language is looked up once,
   for example PingFang SC for Han with `zh-Hans`, and used as an explicit font.

**Script detection.** A table generated from Unicode's `Scripts.txt` replaces the seven hand-written ranges (a
script in `scripts/` regenerates it for a new Unicode version; the generated file carries Unicode's copyright
notice). Han, Hiragana, Katakana, Hangul and Bopomofo are separate scripts in Unicode; the Settings list groups
them as one "CJK" row that can be split. Digits, punctuation and spaces (Common, Inherited) take the script of the
neighbouring token, so a `，` or `2025` inside Chinese text is not drawn at the Latin size.

**Three layers of settings**
1. *Settings ▸ Appearance:* a font and a size for each script. There is no global font. Latin starts as Menlo 12
   (the old global font), and "All other scripts" is the system fallback at the Latin size. The old overrides are
   migrated with the Latin size, so nothing looks different after the update.
2. *Settings ▸ Corpora:* two columns for each corpus, **Row height** and **Language** (BCP-47). Both start
   automatic (shown grey, for example `auto (22)`), can be typed over, and go back to automatic when cleared.
3. A global override below the Corpora table: use one row height for every corpus.

**What the corpus scan does.** On the first open of a corpus (and again when its size changes) the app reads the
corpus's list of distinct word forms (`form.lex`: 3.1 million forms, 40 MB, 0.07 s to read for UD 2.18) and counts
the scripts by form. It finds even tiny ones (Kannada: 2 forms, Ogham: 13), which no sample would. Scripts above
0.2% of the distinct forms set the default row height, the tallest line among them at their sizes. Counting forms
and not tokens matters: Han is 0.8% of the tokens in a UD sample but 2.2% of the word list, so it passes the
threshold, while a few quoted words in an English corpus do not. Scripts below it are still drawn in their own
font, at a size capped to fit the row. The result is cached in the app's settings (no hidden files, nothing next
to the corpus). If `form.lex` can't be read (its layout is pando's, not an API), an evenly spaced sample of tokens
is the fallback. A row height typed by the user, or the global override, means the scan does not run.

**The default language.** Kana in the corpus means `ja`, Hangul means `ko`. Han-only text goes through
`NLLanguageRecognizer` on a sample of sentences. When it is unsure the language stays automatic, which is today's
behaviour. A corpus that mixes Chinese, Japanese and Korean (UD) has no single language, so it stays automatic.

**Why a fixed row height, not per line.** `NSTableView` places rows from their heights; with variable heights it
has to ask for every one. A result of millions of hits, with its rows loaded a window at a time, needs the fixed
row height of today. The row height is therefore a property of the corpus.

## Not doing
- A language per row from the `text_langcode` region value: not available for a shuffled or sampled result of
  millions of hits, so only a possible refinement for results in corpus order.
- A script-to-font table of 177 rows: the list shows only the scripts that have been set, and "Add script…" offers
  all of them, searchable.

## Tests
Script detection against fixed samples of every group; migration of the old settings; row height from the tallest
size; the global override stops the scan; the font cache returns one object per (name, size); a per-script size
reaches the attributed string; the language tag is present on Han runs of a corpus that has one.
