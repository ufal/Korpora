# Trees: showing the dependency tree of a sentence (plan, 2026-11-08)

Status: plan only, nothing built. First for the Sentence view of a concordance; later maybe for queries
(a query drawn as a tree, see the node-picker notes in the frequency and collocation design) and for
frequency results.

## What the user gets

When the concordance is in **Sentence** mode, a button on the right border of a row (or on the selected
row) opens the tree of that sentence: words in sentence order along the bottom, an arc or an edge from each
word to its head, the relation label on it, the matched words highlighted. The window is small and
stays beside the concordance; arrow keys step to the previous and next hit.

## Two drawing styles (from the request)

1. **`tikz-dependency` style** (as in LaTeX papers): the words in one line, arcs above the line from head to
   dependent, labels on the arcs, the root marked by an arrow from above. Compact, readable for long
   sentences, familiar from papers. UD's own viewers (brat, Grew, UD Annotatrix) draw it this way too.
2. **PDT style** (the UDPipe web service, Treex): a real tree. The root at the top, children below their
   head, left to right in word order, the word and its label in each node. Better for seeing the
   shape of the structure and deep nesting; wide for long sentences.

The UDPipe viewer is `web/lindat-service/js-treex-view.min.js` in `ufal/udpipe` (181 KB, minified,
jQuery plugin `treexView`, uses d3). It renders Treex JSON in a web view. **We do not reuse it**: it is a
JavaScript library, which means a `WKWebView` in a native AppKit app, a bundled jQuery, d3 and a minified
file we can't maintain, and I found no licence notice in it (the UDPipe repository as a whole is MPL-2.0;
that would have to be checked file by file before bundling). We take the *look* of the PDT style, not the
code.

**Recommendation: draw both ourselves in AppKit/CoreGraphics, with a toggle** (Arcs | Tree), arcs first
because it is the simpler layout and the right default for a concordancer (sentence order stays visible,
so it reads like the sentence row above it). Both need the same layout inputs, so the second style is a
second drawing routine, not a second feature.

Why native and not a web view: the fonts and sizes per script and the per-corpus language (typography.md)
apply to the tree's words as well, with the same resolver; copying, drag, printing and PDF export are the
system's; no web content in a corpus tool; and a window of 20 to 80 words is trivial to draw.

## What the tree needs: the data

For one sentence: for every token its **id, form, lemma, upos, feats, head and deprel**, and the
information which tokens the query matched (for highlighting).

What pando gives us today (checked 2026-11-08, pando 0.4.8):

| route | head? | verdict |
|---|---|---|
| `pando` CLI `--conllu` | yes: full sentence as CoNLL-U (`head`, `deprel`, `# sent_id`, `# text`, and `# pando_match_tokens = 34,37` for the matched tokens) | exactly what we need, but CLI only |
| C API hit page (`attrs`, `sentence`) | no: `head` is not a positional attribute; `deprel` is | not enough |
| C API `tabulate` | no: `match.head` is "unknown token or region attribute"; `match.deprel` works | not enough |
| `match.head`-like fields in `pando_query` | no | |

So **the heads are not reachable through the C API.** This is a request for pando, in the same spirit as
the region-values one: a way to get the dependency structure of a sentence, either

- an `attrs` value `head` (and `id`, the position in the sentence) in hit pages, so that a Sentence-mode page
  already carries the tree; or
- a `"conllu": true` option on hit pages (as the CLI's `--conllu`), returning the sentence as CoNLL-U with
  the match tokens marked.

Either costs pando little (the dependency index is there: `dependency_index.h`). The user files pando
issues himself; a draft can be written when the plan is accepted. **Fallback with no pando change:**
none that is honest. Reading the dependency index files directly would depend on pando's on-disk layout,
which is not an API (the same objection as for the `.lex` scan, which was accepted only for a cache that
may fail). So: ask pando first, build the viewer against a protocol that can be backed by either option.

## Design

**Engine layer** (`KorporaEngine`): `SentenceTree` (tokens: id, form, lemma, upos, feats, head, deprel;
`matched: Set<Int>`; `sentID`, `text`), and one method on `ConcordanceHandle`,
`sentenceTree(at hit: Int) -> SentenceTree?`, nil for a corpus without dependencies. The pando
implementation parses the CoNLL-U or the head attribute, whichever pando offers. The mock engine returns a
fixed tree for tests.

**Layout** (pure functions, unit-testable without a window):
- *Arcs*: x positions from word widths (measured with the script fonts) and a gap; an arc per dependency;
  height proportional to the span, so that nested arcs nest and crossing arcs show non-projectivity;
  label centred on the arc; root arrow. Long sentences: horizontal scroll, not shrink.
- *Tree*: classic layered layout on word order: leaves in word order, a parent above the middle of its
  children (a Reingold-Tilford variant is overkill; "x of the head = mean of its children, then separate
  overlaps" is enough for a sentence); a straight edge with the label beside it.
- Enhanced dependencies (the CoNLL-U column 9, `10:nsubj|...`): not drawn in the first version.

**View** (`SentenceTreeView`, an `NSView` in an `NSScrollView`): draws with CoreGraphics and the same
`ScriptFontResolver` fonts; colours from the system palette (dark mode); matched words in the
concordance's match colour; hover shows lemma, upos and feats in a tooltip (as the concordance tooltips do);
click on a word selects it and its subtree. Accessibility: each word is an accessibility element with its
head and relation as the label.

**Window**: `SentenceTreeWindowController`, one window that follows the selected row (so there are not
twenty windows), with Arcs | Tree, previous and next hit, Copy as image, Save as PDF/SVG, and "Copy CoNLL-U"
(the sentence, ready to paste into a treebank tool).

**Button**: in Sentence mode, a small tree glyph at the right border of the row (a trailing accessory in the
KWIC cell), shown only for corpora with dependencies; also View ▸ Show Tree (⌥⌘T) for the selected row. It
loads the one sentence on demand (one request for one hit: a few milliseconds), never the page.

## Open questions
1. Which pando route (head in hit pages, or CoNLL-U output)? The user's call, to be asked of pando.
2. Does the Sentence view always hold the whole sentence? (`context` = the enclosing sentence: yes, but a
   hit across a sentence boundary has more than one; the tree is for the sentence of the first matched
   token, the others get a "next sentence" step.)
3. Corpora without dependencies (SYN 2025 has `deprel`? to check): the button is hidden when pando says
   there is no dependency structure.
4. SVG export: easy for arcs, a few lines for the tree; PDF comes free from `NSView.dataWithPDF`.
5. Left-to-right scripts only in the first version; right-to-left (Arabic, Hebrew) mirrors the word order
   and needs the layout to be flipped. Plan for it in the layout inputs (a `direction`), build later.

## Steps
1. Pando request drafted (head in hit pages or CoNLL-U output); meanwhile the layout code and
   `SentenceTree` with a CoNLL-U parser, tested on the CLI's output for UD sentences (non-projective ones
   included).
2. `SentenceTreeView`, arcs; the window; the button; mock engine; snapshot tests.
3. Tree layout, the toggle, export.
4. Docs: this page's "Built" section; project plan.
5. Later: a query as a tree (nodes picked as in the frequency design), frequency results beside it.
