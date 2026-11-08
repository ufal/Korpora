# Frequency composer: frequencies over the nodes of a query (design, 2026-11-08)

Status: design, nothing built. Target: version 0.5. Collocations reuse the first and third parts (see the end).

## The problem

KonText describes a frequency by *positions*: "the 2nd word to the left of the KWIC", "the node", up to five levels, each
an attribute and an offset from the start or the end of the match. That works because a KonText match is one
contiguous string. A pando match is not: a query can be several tokens joined by dependencies (`a:[lemma="give"] > b:[deprel="obj"]`),
in any order in the sentence, with other words between them. "Position 2 from the left" has no meaning there.
What has a meaning is the **node of the query**: *the verb*, *its object*.

So a frequency is: **for node N take attribute A**, repeated for several (node, attribute) pairs, which is
also what makes multi-level frequencies (one attribute of node N, another of node M) possible.

## What pando gives (checked 2026-11-08 on the UD index, pando 0.4.9)

- `freq by a.lemma, b.upos` after a query with named tokens returns **flat rows**: `{"key": "give\tNOUN", "count": 1178, "pct": 80.35, "ipm": 30.85}`.
  `count by …` gives the same data as a tree (levels in the order of the fields); the app uses the flat form.
- Names are written in front of a token: `a:[...]`. A query without names has no way to say "the second token", so **Korpora
  adds names** to the query text it sends. Names the user wrote are kept.
- A hit's `tokens` are in **query order** (a, then b), whatever their order in the sentence, each with its position
  (`pos`); `match_start` and `match_end` bound the hit. So node *i* is `tokens[i]`, and its word in the hit text is the one at
  `pos − match_start`.
- **Not available:** an offset from a node in `freq by` (`b[1].lemma`, `match[-1].upos` are syntax errors), so no
  "the word after the object" in the first version.
- **Unclear:** a named token with a repeat (`a:[upos="ADJ"]{1,2}`) or optional (`a:[upos="ADJ"]?`) runs, but which token `a` means in a repeat
  is not documented, and the number of tokens in a hit varies, which breaks the node-to-token mapping above.
- Groups in parentheses are not pando-CQL (pando says so), so the scanner does not handle them.
- Pando orders the rows by count, descending. It has no sort by key, and its string order is by code point, not a collation.
  **`freq` has no row limit** (checked on UD: all 712,305 noun lemmas come back, in 2.5 s; the `limit` option does not apply, `group_limit`
  is for `count` trees) **and no group count**. So the engine keeps the first 100,000 rows itself, says it did (`isCut`), and the
  coverage is `sum of the rows' counts` against `total_matches`: "these rows cover X of the Y hits".
- **No case folding in `freq by`** (`lower(…)`, `%c` are syntax errors there): "ignore case" is done in the app by merging the rows
  whose values differ only in case (counts and percentages added, shown in lower case).

## The idea: the query is the picker

The window shows the **query text** with each token drawn as a coloured span, a small **badge** (a, b, c) on
it, and below it **the first hit** with the same colours on the words that node matched. Arrows step to the
previous and next hit. The user clicks a node (a span in the query, or the same coloured word in the hit),
a popover lists the attributes of the corpus, and choosing one adds a **line to the table below**.

```
 Query   [a lemma="give"] > [b deprel="obj"]               (a = blue, b = orange)
 Hit 1   … som spillerne mener  giver   dem urimelige  vilkår  . …     ◀ 1 of 1,466 ▶
                                (a)                    (b)

 Node  Attribute   Ignore case   Sort        
 ● a   lemma       [ ]           ▲▼          ≡  ⊖
 ● b   upos        [ ]           ▲▼          ≡  ⊖
 + Text or document property…                         [ Count ]
```

- **Names.** Badges are letters. If the user named a token (`verb:[…]`), the badge shows their name. The names we
  add avoid every name in the query. Names were never shown before; they are now part of the picture, and nothing is hidden: the
  query shown is the user's, the names we insert appear only as badges and in a "Show the query as sent" disclosure.
- **Colours.** One colour per node, used in four places: the span in the query text, the word in the hit, the dot in the
  table line, and the result column header. Colours come from the system palette and also differ by shape (badge letters), so
  colour is never the only cue.
- **The table line.** Node (colour dot and badge), attribute (a pop-up), ignore case, sort direction ▲▼ (a stepped icon), a drag handle
  to reorder, a remove button. A pseudo-node "Text or document property" keeps what the current sheet does
  (`doc.author`, with its `norm` and ipm), which belongs to no token.
- **Several lines for one node** are normal (`a.lemma` and `a.upos`).
- A node with a repeat or optional mark (`{1,2}`, `?`, `*`, `+`) is shown with a mark and is **not pickable** in the first
  version (the meaning of `a.attr` for it is unclear and its tokens do not map to the hit). The tooltip says why.

## Order and sorting

- **The order of the lines does not change the counts**: a flat `freq by` gives the same combinations in any order.
- It changes (1) the order of the result's columns and (2) the **sort priority**.
- Pando returns the rows by count; **sorting by a column is done in the app**, per line ▲▼, with the order of the lines as
  priority and the count as an option (a "Count" pseudo-line, also ▲▼, first by default). Strings compare with
  `localizedStandardCompare` (or the language of the corpus), which is the collation that pando's code-point order lacks.
- **Cut rows.** Sorting by a key sorts only the rows we received. If pando cut the result (the top 100,000 by count) the
  window says "these rows cover X of the Y hits" and the ascending sort by key is marked as of the shown rows. (pando's `freq` doesn't
  say how many combinations there were, so there is no "N of M combinations".)

## The first hit

- Fetched with the call the extended context already uses for one hit by number (`hitPage(offset:count:1…)`), so it is correct for sorted,
  shuffled and sampled results; the arrows ask for the neighbouring hit, and the window keeps the last few.
- Words to colour: `tokens[i].pos − match_start` for node *i*, in the hit text. The hit text is pando's `context`, in which tokens are separated by single
  spaces, so the word index is the token index; if a hit cannot be mapped (a different token count than nodes), it is shown uncoloured with a
  note, not guessed.

## Parts

1. **`QueryNodes`** (engine layer, pure): scans a pando-CQL text and returns its token spans (`[` … matching `]`, with the
   quoted strings and brackets inside a value skipped), the user's name in front of each (`name:`), its repeat or optional mark, and a
   function that returns the query with the names inserted. Tested on: unnamed and named tokens, dependency arrows, `::` conditions, quoted
   brackets, repeats, regions (`<s>`, not nodes), comments. Built (`KorporaEngine/Sources/KorporaEngine/QueryNodes.swift`, 13 tests; pando accepts the text it
   writes). `CQLCompletion.swift` has no tokenizer to share (only bracket-depth and open-quote checks), so `QueryNodes`
   is a small scanner of its own with the same quote and `/regex/` rules. Generated names skip `s p t text doc match matchend`, which pando reads
   as regions or the hit after `::`; a query starting with a dialect keyword (`MANATEE`, `PMLTQ`, `CWB`, `TIGER`) is not scanned.
2. **`FrequencyField`, `FrequencyTable`, `frequencyTable(_:minFrequency:)`** (engine layer; built, 14 tests plus a UD one): lines of (node, attribute, ignore case), plus text and document properties; a method on
   `ConcordanceHandle` that writes the `freq by` text, runs it and returns rows with their per-field values split out
   (today the key arrives tab-joined in one string) and the cut information. The old single-attribute
   call stays for the old sheet until the composer replaces it.
3. **The composer** (AppKit): the query strip (an `NSTextView` or a custom view drawing the spans), the hit strip with arrows,
   the attribute popover, the table (an `NSTableView` with drag reorder), Count. It replaces the Frequencies
   sheet. The results go to the existing Frequency window, with a column per line and the node colour on its header.
4. **Results**: sort in the app with the priorities above, the "N of M" note, copy and export as before.

## Not doing (first version)

- Offsets from a node ("the word after the object"): pando can't (a request for pando later, if wanted).
- Repeated and optional nodes as picks.
- A tree result (`count by`): the table is flat; the hierarchy can be a later view over the same rows.
- Frequencies of `dcoll`-style relations: for the word-profile work.

## Collocations (the next page)

The same query strip and the same hit strip, one node chosen as the **anchor**, and pando's `coll on <node>` (tested: it exists and gives
different results from the whole-match window: for `a:[lemma="give"] > b:[deprel="obj"]` with ±2, the verb's window shows the indirect objects
*me, you, him, us*, the object's window and the default window do not). "Whole match" stays the default and is the other choice. No `dcoll`
for now.

## Tests

`QueryNodes`: spans and names on the cases above; the inserted names never clash. `FrequencySpec`: the text written for
several lines and for text and document properties; the rows split into per-field values; the cut note. Composer:
adding, reordering and removing lines; the sort priority and direction on fixed rows (including accented strings); the colours of
node *i* in the query and in the hit; an unmappable hit is shown uncoloured. A real-corpus test on UD (needs the pando build) for
`a > b; freq by a.lemma, b.upos` giving `give⇥NOUN` first.
