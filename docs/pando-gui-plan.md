# Korpora on pando only: GUI integration plan (2026-11-03)

Decision (owner): drop the Manatee integration; pando is the only engine. Manatee-specific features are dropped or re-engineered for
pando. The evidence is in `docs/pando-analysis.md` (SYN2025 head-to-head, UD import, GUI feature analysis). Working branch:
`spike/pando-engine` (pushed), merged to `main` when the app is green.

Test data: pando built by `scripts/pando-spike.sh build`; UD 2.18 (712 treebanks, 38.2M tokens, 5.3 GB) indexed with
`scripts/pando-spike.sh ud`; SYN2025 as converted for the benchmark (`~/Developer/pando-work/syn2025/idx`, Prague-style labels).

## Principles
- A corpus is a **pando index folder**. The library shows corpora, not registries; vocabulary users never need
  ("registry", "compiled corpora directory", "encodevert", ".subc") disappears from the UI.
- Whatever the app does for a corpus it does through the engine protocols (`CorpusEngine`, `CorpusHandle`, `ConcordanceHandle`), so
  tests use fake engines and a remote (FQS) backend can be added later.
- Do not emulate what pando does natively; do client-side what the app already holds in memory (all hit lines).

## Decisions
| Area | Decision |
|---|---|
| Packages | `ManateeKit` becomes `KorporaEngine`: one module (`CorpusEngine` protocols and values + the pando engine + corpus library + import). `CManatee`, `manatee-open`, pcre2, `encodevert`/`mkregexattr`, `build-release-deps.sh`' Manatee parts are removed. |
| Loading pando | `libpando.dylib` via `dlopen` (as the spike); bundled in the app's Frameworks for releases, `$KORPORA_PANDO_LIB` / `~/Developer/pando-work/pando/build` for development. |
| Corpus library | `~/Library/Application Support/Korpora/Corpora/<name>/` holds a corpus built by Korpora; linked folders are symlinks in `.../Linked/`. Identity = name (unique). Size and attributes from `corpus.info`, no open needed. Old Manatee data is ignored (left on disk). |
| Import | "Import CoNLL-U" (files or folders, many treebanks into one corpus) running the bundled `pando-index` with progress parsed from its output. The workshop (plain text, docx, ... via Flexiconv/Flexipipe) comes after. |
| Keep in Memory | Kept: the residency manager already works on a data directory (reads index files into the page cache), so it applies to pando index folders as is. |
| Subcorpora | Saved **restrictions** (name + attribute/value picks) per corpus in `Subcorpora/<corpus>.json`; applied to every query as a region filter `:: match.doc_genre = /a|b/ & ...` (regex alternatives verified). The picker (values with counts, search) is kept, fed by `show values`. |
| Query language | pando-CQL only. Colouring, completion and the History popover updated; `--cql manatee` dialect is not used. |
| Default attribute | `CorpusInfo.defaultAttribute` (`form` when present, else `word`), used where the app hard-coded `word`. |
| Sort / shuffle / sample / line groups / dispersion | Client-side on the loaded lines (`ClientSideConcordance`): sort by attribute at kwic/left/right (left/right context attributes limited to what pando returns; see upstream list), shuffle and sample random, line groups kept in the document, dispersion binned from hit positions. |
| Positive/negative filter | Dropped (Manatee-specific). |
| Structure column per hit, Extended Context | `tabulate` (region attributes of each hit, positions) and a re-fetch of one hit with a wide context. |
| Documents | `.corpconc` format version 3: engine id `pando`, `restriction` replaces `subcorpusPath`; a Manatee document opens to a clear "made with the old engine" message. |
| Settings | Corpora tab rebuilt (Name, Source, Tokens, Keep in Memory; Add folder, Import, Remove); remove registry directories, Manatee environment handling and the vertical-import attribute sniffing. |

## Upstream asks for pando (Maarten)
Attributes on context tokens (not only the match) for inline/tooltips and sort keys; a `region at position` lookup; a histogram of hit
positions; warn when CoNLL-U metadata values with spaces are dropped (`# text_X` vs `# meta::X`); `sort`/`cat` through `pando_run`.

## Phases (each ends with tests green and a commit)
1. **Engine package**: merge into `KorporaEngine`; `PandoCorpusLibrary`, `PandoImporter`, `SubcorpusRestriction` for pando, residency; tests.
2. **Client-side operations layer** over pando queries; structure columns and Extended Context via `tabulate`; analyses.
3. **App**: unified library in Settings and the New Concordance sheet, import sheet, subcorpus picker, query field profile,
   document format v3, hard-coded `word` removed; delete the Manatee-only UI (filter sheet, registry settings).
4. **Remove Manatee**: C bridge, manatee-open, scripts, project.yml helper phases, tests; CLAUDE.md and plan docs.
5. **Packaging**: bundle libpando and pando-index in the app, sign, release script, smoke test on the macOS 15 VM.

## Status (2026-11-03): phases 1-5 done on `spike/pando-engine`

- **Engine** (`KorporaEngine`, 70 tests): protocols, `PandoEngine`/`PandoConcordance` (loads up to a limit of hits, in-memory
  sort, shuffle, sample, line groups, histogram; region attributes and wide context by `tabulate` and a re-fetch),
  `CorpusLibrary` (built and linked corpora), `CorpusImporter` (`pando-index` with progress, cancel, atomic rename),
  `Subcorpus`/`SubcorpusRestriction` (saved restrictions applied as region filters), `CorpusMemoryResidency`.
- **App** (173 tests): library in Settings (Tokens column, import from CoNLL-U/folders, add/remove, Keep in Memory),
  New Concordance sheet, subcorpus picker (values with document counts), sort popover, load limit in Settings, document
  format 3, pando-CQL colouring and completion. Removed: the filter sheet and "Filter to Selection", the sentence view
  (KWIC only), the CQL-expression mode of subcorpora, registry settings, the vertical import sheet.
- **Release plumbing**: `build-release-deps.sh` builds pando at the macOS 15 floor; `make-release.sh --skip-notarize` makes a
  signed app with `libpando.dylib` and `pando-index` bundled (6.9 MB; the DMG 4.3 MB). Not yet: a notarized release, and the VM
  smoke test (updated for pando, not run).
- **Checked by launching the real app** (Release config, Debug build) on the UD, SYN2025 and sample corpora: the New Concordance
  sheet, and a saved document running `[lemma="ruka"]` on SYN2025 with the document-title column and a left-word sort.
  Not clicked through: the import sheet, Settings, the subcorpus popover, collocations/frequency/dispersion windows,
  Extended Context, print. Their logic is covered by tests.

### Naming
A corpus's name is Korpora's own handle, not the index folder's: adding one index folder asks for a name (default: the
folder's, or its parent's when the folder is called `idx`/`index`/...); importing asks for one; and any name can be changed
by clicking it in Settings > Corpora. A built corpus's folder is renamed, a linked corpus's link is (the folder is never
touched); Keep in Memory, saved subcorpora and search history follow the new name. Saved concordance documents still name
the old corpus and won't find it after a rename.

### Settings window
Follows the HIG for settings windows: it reopens on the pane last used, where it was left, and at the size the user gave each
pane (never below the pane's designed size or beyond the screen); switching panes keeps the top-left corner in place. In
Corpora the Name column is the flexible one (the others are as narrow as their headings), column widths the user sets are
remembered, a long folder path is shortened rather than widening the window, and the periodic memory refresh does nothing
while a name is being edited.

### Differences users will notice
- A search shows every hit, however many: the table reads lines from pando a window at a time as it scrolls (a result of
  millions of hits needs no more memory than a few screens). A result up to 100,000 hits (Settings > Concordance, "Full
  sorting options up to") is sorted, shuffled, sampled and grouped in memory with every option. On a bigger one pando does
  one-key sorts (`sort`, paged with `cat`), shuffles and samples itself, on all hits (pando 0.4.2); several sort keys,
  retrograde, unique and line groups work on the first 100,000 hits of the current order and the status line says so.
  pando sorts in code-point order (capitals first, `%c` only folds case), where the in-memory sort follows the language's
  alphabet; the region column and "Document Info" are blank/unavailable for shuffled or sampled hits of a big result (pando's
  hit pages carry no region values).
- Words around a hit show their spelling only (no lemma/tag under context words; sorting by left/right words is by spelling).
- No positive/negative filter, no sentence view mode, no `.subc`-style typed subcorpus expressions.
- Subcorpora are picks of document properties, saved per corpus; they restrict every search in them.
- Frequencies have a "Per million" column and chart measure (pando's `freq`: relative to the tokens of the value's documents
  for a document property, to the whole corpus otherwise - the same as Manatee's "norm"-based figure, plus the latter).
- Old `.corpconc` documents (format 1-2) don't open: a message says why. Old Manatee corpora are not read.

### Asks for pando (Maarten)
Attributes on context tokens; sentence-bounded context, `shuffle`, `sample`, `seed` and cached sorted paging through the C API (draft: docs/pando-issue-c-api-options.md); a hit-position histogram; a warning when CoNLL-U metadata values with spaces are dropped (`# text_X` vs
`# meta::X`); a licence.

### Next
Click-through of the whole UI; the workshop (plain text and documents to corpus through Flexiconv and Flexipipe in a
downloaded Python environment); pagination beyond the load limit (6.11); UD-aware word profiles.

## Query completion and patterns (2026-11-04)

The query bar completes pando-CQL only (no Manatee spellings): between tokens the region words
(`within`, `containing`, `having`, `subtree`, `not`) and the dependency arrows (`>`, `<`, `>>`, `<<`,
`!>`, `!<`); inside a token the attribute names plus the relations `child`, `parent`, `ancestor`,
`descendant`, `sibling`, `next`, `prev`, `after`, `before` (after `not`, too); after `::` the global
functions (`distance`, `strlen`, `nchildren`, the date functions, ...). Brackets nest (a closed inner
token no longer ends the outer one) and brackets in quoted or `/regex/` values don't count. The
relation words are coloured only directly before a `[`.

The button at the right of the query field ("Insert pattern") inserts starting points with the caret
in the right place: relations inside a token, arrows between two tokens, UD examples (greyed out when
the corpus has no `upos`/`deprel`) and region forms. Every template is checked against real pando.

Not done: the `;` commands (`count`, `tabulate`, `stats`, `keyness`, `dcoll`), because the app has no
window for their results yet; completing attribute values. See the aggregates list in the 1.0 notes.

## Corpus list: linked corpora and the corpora folder (2026-11-05)

- A linked corpus whose index folder moved stays in the list, marked "Missing" with a warning icon (it used to
  disappear: `CorpusLibrary.entries()` only lists folders with a `corpus.info`; `entries(includingMissing: true)`
  adds the broken links, and everything that searches leaves them out).
- Double-click on a row opens the corpus's folder in Finder (a missing one asks where it went, the Relink
  dialog). Renaming is by a click on the name of a selected row, or Return (the Finder convention).
  The contextual menu has Show in Finder, Rename, Relink... (linked), Bring into Korpora... (linked: copy or
  move the index into Korpora's folder; the name, subcorpora and history stay) and Remove.
- Nothing Korpora makes is hidden (the user's rule, memory `no-invisible-files`): removed-but-kept corpora go to
  "Removed Corpora"; work in progress (an import being indexed, a corpus being copied) is kept in "Unfinished
  Work" in the corpora folder (on the same disk) and removed when done; hidden folders from early versions
  (`.Removed`, `.importing-...`) are made visible at launch, nothing deleted.
- Copying or moving corpora (Bring into Korpora, changing the corpora folder) shows a progress sheet with a
  progress bar, bytes done, an estimate of the time left (after a few seconds) and Cancel. Files are copied in
  chunks and a cancel removes the partial copy and leaves the original; the sheet only appears if the job takes
  more than a moment (within one disk it is a rename).
- The folder for corpora Korpora builds can be chosen in Settings > Corpora (Choose..., "Reset to Default"
  to go back), for example on an external disk. When corpora are in the current folder, a dialog asks whether
  to move them along (each goes through a hidden name and is renamed into place; an existing corpus of the same
  name in the new folder is never overwritten) or leave them (they stay in the old folder and are no longer
  listed). If the chosen folder's disk is not connected, the path shows in red, the list is empty and an
  import says so instead of making the folder. Linked corpora (small symlinks), subcorpora and the "Removed Corpora"
  folder are not moved. `KORPORA_CORPORA_DIRECTORY` still overrides everything (tests).

## Scope for 1.0 (decided 2026-11-03)

In: the pando-only concordancer as it is, with menu commands for every toolbar action and a
customizable toolbar (done); still to do: exercise the release path (notarized build, clean-VM smoke
test), settle pando's licence for redistribution. (Paging beyond the old 10,000-hit cap is done: see "Paging long results".)

Out, for 2.0: importing more formats and plain text (the corpus workshop, via Flexiconv/Flexipipe), a
remote FQS backend, and importing CWB-vertical (`.vrt`/`.vert`) corpora, both from the Import button and by
dragging them on the app icon. `pando-index --format vertical` already reads them without a registry file:
structures and region attributes come from the file's tags, column names from an optional
`<!-- positional-attributes: word lemma tag -->` first line; without it three columns are guessed as
`form,lemma,upos`. So the Manatee-era sheet that names the columns comes back for files without that line.
Corpora are positioned as having syntax, so a vertical corpus without it comes with an offer to parse it.
For 0.4/1.0 dragging a CoNLL-U file on the app icon opens the existing import sheet; no temporary corpora. The pando limits (attributes on context tokens,
sentence context through the C API, hit-position histogram) are not tied to a release: support is
added when a feature needs it.

## Paging long results: measurements (2026-11-05)

Question: can the concordance work the way Manatee/KonText do (hit positions only; text lines made for the visible window)
instead of loading up to 10,000 complete lines? Measured through the C API (`pando_query` / `pando_run`, pando 0.4.1) on
SYN2025 (122 M tokens), query `[lemma="být"]` (3,978,146 hits), context 10, one handle, warm file cache:

| Operation | Time |
|---|---|
| total (`limit 1`, `total`) | 1 ms (cached) |
| page of 50 at offset 0 / 1,000 / 100,000 | 1 / 0.4 / 6 ms |
| page of 50 at offset 1,000,000 / 3,000,000 | 48 / 149 ms |
| single hit at a random offset (up to 3 M) | 72 ms |
| `M = …; sort M by form %c on matchend[1]..matchend[3]` + a page | 5.4-6.2 s |
| the same sort again, on the same handle, another offset | 2.3-5.5 s (no reuse) |

Findings:
- Windowed fetching is fast at any depth, so a lazy table (rows fetched by `offset`/`limit` for the visible window, a small
  window cache) needs no 10,000-hit cap for hits in corpus order.
- Sorting works through `pando_run` but the whole result is sorted on every call (seconds for millions of hits). The
  session keeps `M` (`show named` says materialised) but there is no C API statement that pages it without sorting again.
  The server API caches sort indexes and sorted pages (`--cache-mb`); the C API does not expose that.
- `shuffle`, `sample` and `seed` exist in the HTTP API only; `parse_query_opts`/`parse_program_opts` in
  `src/api/pando_ffi.cpp` do not read them (like `sentence`).

Done (2026-11-05): `ConcordanceHandle` reads lines by range; `PandoConcordance` is *windowed* until the first operation and
*loaded* (first `limit` hits, default 100,000) after it; `ConcordanceDocument` keeps chunks of 200 rows (100 chunks at
most) and the table asks for the ones on screen (`NSTableViewDataSource`, no diffable snapshot of millions of ids; an
`NSTableView` with 4 million rows reloads in milliseconds). Export writes a chunk at a time to a temporary file that then
replaces the target. The issue to file with pando is docs/pando-issue-c-api-options.md.

Asks for pando: sorted paging with the sort cached per handle (or `Last`/a named set as a page source), and `shuffle`,
`sample`, `seed` (and `sentence`) in the C API options.

### Update (2026-11-05, pando v0.4.2-0.4.4)
pando answered the asks within a day: `sentence`, `shuffle`, `sample`, `seed` in `pando_query` and `sentence` in `pando_run`;
`cat M from to` pages a sorted set (4.6 s for the first sort of 4.3 M hits on UD, then milliseconds; shuffle 0.1 s at
offset 0, 1.7 s at offset 3 M); CoNLL-U metadata values with spaces are kept; MIT licence. `PandoConcordance` uses them for
results larger than the in-memory limit (see "Differences users will notice"). Still missing, to ask for: region attribute
values in hit pages (`attrs` accepts only token attributes), a sort order by language (collation), several sort keys.
