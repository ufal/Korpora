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
