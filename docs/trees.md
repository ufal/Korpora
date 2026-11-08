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

The UDPipe viewer is a minified build of **`ufal/js-treex-view`** (MIT, Copyright 2015 ÚFAL; 1,626 lines of
JavaScript with jQuery and d3). The licence allows reuse, but a JavaScript library in an AppKit app means a
`WKWebView` and a bundled toolchain, so **we do not reuse the code, we take its algorithm and look** (below)
and keep the copyright notice in `docs/` where we cite it.

## What js-treex-view does (read from the source, 2026-11-08)

**Tree layout** (`lib/Layouts.js`, `tree()`): about 40 lines.
1. Sort the nodes in word order. Each node's row is its **depth** (root 0).
2. Row heights: the tallest node of each row; row *d* starts at the sum of the heights above it plus
   `(nodeYSkip + marginY) * d` (constants: `nodeXSkip` 10, `nodeYSkip` 5, margins 2).
3. x, walking the nodes in word order with a running `left`: `left` = the larger of (`left` + `nodeXSkip`) and
   (right edge of the last node already placed **in the same row**) + `nodeXSkip`; the node's x is `left` plus
   a 2-pixel step per node.
So **x never goes backwards in word order, nodes in one row never overlap, and a parent is not centred over
its children**: it sits at the x its own word order gives it (the layout is an *order-preserving* tree, so a
reader can still read the sentence left to right across the tree; edges slant). No tree-shape optimisation
is needed, which makes it simple, fast and stable between sentences. It works for non-projective trees
as they are. That is the layout we build for the Tree style.

**Drawing** (`lib/Stylesheet.js`, a-layer): a node is a small circle (r 3.5, a-nodes pink `#ff6666`, 1 px
`#555` outline) and **below it a label** on a white 90% box, 12 pt Arial, several lines (form; then other
attributes, each line can carry its own colour). Edges are straight 2 px `#555` lines between node centres
(a dashed 1 px line for some functors in the t-layer, not needed). Several trees (layers, languages) are
drawn side by side with a 10 px gap. A constituency variant puts the leaves on the bottom row and draws
right-angled ("Manhattan") edges with dashed leaf links: not needed for UD.

**Interaction** (`TreeView.js`, `Attributes.js`, `Hint.js`):
- *Hover* a node: its word in the sentence text above the tree is highlighted, and a tooltip (`hint`)
  follows the pointer.
- *Click* a node: it is selected (red 1.5 px outline, 10% red fill); clicking it again deselects. The
  selection opens a **300-pixel side panel with a table of the node's attributes**: name and value rows,
  bold names, sorted by name, **nested attributes expandable** (a row whose value is a group opens as a
  sub-table), and a **"hide empty" checkbox, on by default**.
- *Click a word in the sentence text*: a ring grows from the node and fades (1 s), so the eye finds where
  the word is in the tree.
- A pager steps through the sentences (bundles) of a document.

## What we take from it
- The **order-preserving tree layout** for the Tree style: exactly the three steps above, in Swift, with the
  word widths measured in the script fonts. It is a function from (depths, node sizes) to points, unit-tested.
- The **look**: dot plus label below, thin grey straight edges, the label's second line being the relation
  (the original shows the PDT's `afun` in dark blue; we show `deprel`), colours from the system palette.
- The **interaction**: sentence strip above the tree with hover and click linking (here also the matched words
  in the match colour); selecting a node opens an **attribute inspector**, here an `NSOutlineView` in a side
  panel: `id`, `form`, `lemma`, `upos`, `xpos`, `head`, `deprel`, then `feats` as an expandable group (one row
  per feature, `Number=Sing`), then `misc` and every other token attribute of the corpus; "Hide empty" on by
  default; Copy value on a row; the same tooltip as in the concordance on hover; the ring pulse when a word is
  clicked in the strip.
- Not taken: layers, zones, Treex file loading, constituency drawing.

**Recommendation: draw both ourselves in AppKit/CoreGraphics, with a toggle** (Arcs | Tree). Arcs first as
the default for a concordancer (the sentence stays in one line and reads like the row above it); the Tree
style is the js-treex-view layout, which is as short as the arcs one. Both need the same layout inputs, so the second style is a
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
- *Tree*: the order-preserving layout of js-treex-view (above): depth rows, x in word order, no overlap in a
  row; a straight edge from each node to its head.
- Enhanced dependencies (the CoNLL-U column 9, `10:nsubj|...`): not drawn in the first version.

**View** (`SentenceTreeView`, an `NSView` in an `NSScrollView`): draws with CoreGraphics and the same
`ScriptFontResolver` fonts; colours from the system palette (dark mode); matched words in the
concordance's match colour; hover shows lemma, upos and feats in a tooltip (as the concordance tooltips do);
click on a word selects it and opens the attribute inspector (above). Accessibility: each word is an accessibility element with its
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
