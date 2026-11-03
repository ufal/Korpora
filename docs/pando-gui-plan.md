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

### Differences users will notice
- Searches load the first 10,000 hits (Settings > Concordance); the status line says "10,000 of 3,978,146 hits (the first
  ones)". Sorting, sampling and line groups work on the loaded hits.
- Words around a hit show their spelling only (no lemma/tag under context words; sorting by left/right words is by spelling).
- No positive/negative filter, no sentence view mode, no `.subc`-style typed subcorpus expressions.
- Subcorpora are picks of document properties, saved per corpus; they restrict every search in them.
- Frequencies have a "Per million" column and chart measure (pando's `freq`: relative to the tokens of the value's documents
  for a document property, to the whole corpus otherwise - the same as Manatee's "norm"-based figure, plus the latter).
- Old `.corpconc` documents (format 1-2) don't open: a message says why. Old Manatee corpora are not read.

### Asks for pando (Maarten)
Attributes on context tokens; sentence-bounded context through the C API; a hit-position histogram; a warning when CoNLL-U metadata values with spaces are dropped (`# text_X` vs
`# meta::X`); a licence.

### Next
Click-through of the whole UI; the workshop (plain text and documents to corpus through Flexiconv and Flexipipe in a
downloaded Python environment); pagination beyond the load limit (6.11); UD-aware word profiles.
