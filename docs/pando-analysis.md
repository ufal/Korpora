# pando as a syntax-aware engine for Korpora - analysis (2026-09-30)

## Context

Korpora is built on manatee-open (KonText's engine). Manatee only sees a linear token stream with
structure spans, so a parsed corpus gets its syntax flattened into positional attributes (head, deprel)
that CQL cannot join on. `ufal/pando` is a new C++ engine "in the same family" with native dependency
queries, and its `dcoll` command (collocates along dependency edges) is the raw material for
parse-based word profiles ("word sketches" without hand-written grammars).

The user asked for a proper analysis of two options, for both small (treebank) and billion-token
(SYN2025-scale) corpora:

1. pando as a **second engine**, Manatee stays.
2. pando as a **full replacement** of Manatee.

This document is the analysis only; nothing has been built or measured yet. Status: Phase A (measurement spike) done 2026-09-30, results below. Decision on next steps open.

## What pando is (verified from github.com/ufal/pando, 2026-09-30)

- Public GitHub repo, created 2026-03-17, **37 commits, one author (Maarten Janssen, TEITOK)**, 0 stars,
  0 issues, no releases. **No license** (README: "private and experimental"). The user says the author is a
  colleague and licensing is not a problem, so this is a paperwork item, not a blocker.
- C++17, CMake, mmap index directory (`corpus.info`, `.dat/.lex/.rev`, `dep.*`). macOS and Linux;
  developed on macOS. Tools: `pando` (CLI), `pando-index`, `pando-check`, `pando-server` (HTTP/JSON),
  `cwb_import` (CWB import).
- **Embeddable**: `src/api/pando_ffi.h` is a small C API (`pando_open`, `pando_query`, `pando_run`,
  `pando_info`, `pando_free_string`, `pando_close`), JSON in/out, one handle per thread. This is the
  same shape as our `mtcbridge`, and much smaller (6 functions vs 61).
- **Query language**: pando-CQL is modelled on CWB CQL with additions: dependency operators
  (`>`, `<`, `>>`, `<<`), tree restrictions (`[upos="NOUN" & child [upos="DET"]]`, `not child`),
  named tokens, `within`/`containing`, aligned corpora, multivalue and UD-feats attributes,
  `count/freq/coll/dcoll/keyness/stats/tabulate`. A `--cql cwb` dialect exists but is a **subset**
  (no `within`, no `::`, no `|` between sequences). So existing Manatee CQL queries do not carry over
  verbatim, and users of KonText-style CQL would notice.
- **Maturity signals**: README says APIs, formats and flags change without notice; only a handful of
  unit-test files in `src/`; recent commits are performance work (bitset dependency join, Manatee-style
  `.rev` shift-merge). The only scale statement in the docs is the sample script: full UD, "tens of
  millions of tokens". **No published numbers for billion-token corpora or index-build memory.**

## Where Korpora is coupled to Manatee (Explore result)

No abstraction exists: every ManateeKit type is concrete, 21 app files import it, and the plan
never considered another engine. Coupling by layer:

| Layer | Coupling | What replacing/adding an engine costs |
|---|---|---|
| `CManatee` bridge (61 C functions), `ManateeKit` (1,900 lines) | total | New bridge for pando (FFI: ~6 calls + JSON parsing) |
| `ConcordanceDocument` (757 lines), operation types, exporter, KWIC formatter | high: builds `Corpus`/`LiveConcordance` directly; persisted `.corpconc` JSON embeds Manatee shapes (`SortCriteria`, `PNFilterSpec`, `subcorpusPath`), no version field | Needs engine protocols and a versioned document format |
| CQL editing: `CQLQueryField` colouring, `CQLCompletion`, `SubcorpusRestriction` | Manatee CQL and regex-escaping rules baked in | Per-engine language front end |
| Corpus management: registry files, `MANATEE_REGISTRY`, `encodevert`/`mkregexattr` import, `.subc` subcorpora, residency warming | high | pando has directories, not registries; no import UI counterpart; **no persistent subcorpus object** (named queries act as subcorpora) |
| Release: static pcre2, manatee worktree, bundled helpers, signing | build-only | pando needs only CMake and vendored httplib; would simplify release |
| Tests | ManateeKit 112 (all engine-coupled), app 160 (~105 import ManateeKit) | Full replacement invalidates most; second engine adds tests |

Useful seams already present: `CorpusInfo`/`StructureInfo` plain structs, `CQLCompletionContext.at(text:)`
pure function, engine-free `CorpusMemoryResidency`.

## Option 2: full replacement — assessment

Not recommended now. Reasons, in order of weight:
1. **Scale unknown.** SYN2025 is the app's real workload (7.4 GB index, 20+ attributes). Pando has no
   evidence at that size; Manatee is proven there.
2. **Feature parity gaps** for what Korpora ships: persistent subcorpora (`.subc`, the 6.9 value picker),
   sort/filter/shuffle/sample/line-group operations on a live concordance handle, Bonito-style contexts,
   KWIC pagination via `RS(beg,end)`, cooperative cancellation. Pando's FFI is stateless JSON per query
   plus session named queries; each of these would have to be re-derived or added upstream.
3. **Compile pipeline**: users import verticals via `encodevert`; pando indexes JSONL/CoNLL-U. A vertical
   importer would need writing.
4. **Bus factor and format stability**: one author, pre-release formats; every pando format change forces
   a reindex of multi-GB corpora.
5. **Query-language break** for existing KonText users and our saved `.corpconc` files.
Upside that stays true: simpler release (no pcre2, no fork of manatee-open with its own heap-corruption
fix), one engine to reason about.

## Option 1: second engine — recommended path

Manatee remains the default and the workhorse for large flat corpora. Pando is opened for **parsed**
corpora (CoNLL-U/UD, TEITOK exports), where its strengths apply. Corpora carry an engine tag.

Phased, each phase shippable and stoppable:

**Phase A — evidence spike (time-boxed, no app changes).** A "spike" here means a small throwaway
experiment to answer the open questions before committing to design, then discarding or keeping only
the notes. Concretely, in a scratch directory outside the repo:
- Build pando on this Mac (arm64, macOS 27) and on the macOS 15 floor; record build time and problems.
- Index `data/ud-en-ewt` and full UD (tens of millions of tokens); time indexing, index size, RAM.
- Index a **large** parsed Czech corpus slice (10^8–10^9 tokens) or a synthetic one to find the ceiling;
  measure dependency-join and `dcoll` latency and index-build memory.
- Drive `libpando` through the C FFI from a small Swift test: `pando_run` for KWIC, `count`, `dcoll`;
  check thread-safety and the JSON schema stability, and whether session state survives.
- Run 20 representative CQL queries from our tests through native and `--cql cwb` and log what breaks.
- Word-profile prototype: for one lemma, run `dcoll` per relation (nsubj, obj, amod, nmod, …), rank by
  logDice, and compare with what Sketch Engine shows for the same lemma (it already supports
  dependency-parser-fed sketches: sketch grammar output "is formally a dependency parse").
- Ask the author: license (agreed), format-stability plans, subcorpus and pagination plans, whether the
  FFI can expose a cancellable handle.
Output: `docs/pando-analysis.md` results table and a go/no-go per capability.

**Phase B — engine seam (only if A is go).** Extract `CorpusEngine` / `Concordance` protocols from the
concrete Manatee types (targets: `ConcordanceDocument`, `Corpus`, `LiveConcordance`,
`FrequencyCriterion`, `SortCriteria`), keep ManateeKit as the implementation, move engine-specific
persisted fields behind a versioned `.corpconc` format with migration. No behaviour change; existing
272 tests stay green. This step is useful even if pando is later dropped (also unblocks 6.11 pagination).

**Phase C — PandoKit + tree queries.** New Swift package over `libpando` FFI (built as a static lib in
`build-release-deps.sh`, replacing nothing). Corpus list gets an engine column; "Add corpus" accepts a
pando index directory. Query field gets a pando-CQL mode (highlighting, dependency operators in
completion). Unsupported operations (sort criteria, line groups) are disabled per engine capability
flags rather than emulated.

**Phase D — word profiles (the feature of interest).**
- Data: `dcoll <rel> by lemma` per relation for a node lemma+POS; symmetric relations (nmod/obl with
  case markers, conj) need small UD-aware post-processing. Measures logDice/MI/T-score exist.
- Sketch-style grouping is done in UD terms (relation labels), not hand-written grammars, and works for
  any language with a parse; languages without one are out of scope.
- UI (AppKit, our hand-drawn charts are reusable): one window, columns per relation (subject-of, object-of,
  modifiers, prepositional/oblique, coordination), each a ranked list with logDice bars; double-click
  opens the concordance of that pair (a pando `dependency` query); lemma/POS picker; "compare two
  words" (sketch difference) as a second mode.
- Depends on Phase C, and on a parsed corpus; also needs a pipeline to *produce* parsed corpora
  (UDPipe/flexipipe → CoNLL-U → `pando-index`), which could be a later "Parse and import" feature.

**Alternative for word profiles without pando** (cheaper fallback, recorded for the analysis): parse with
UDPipe, precompute a triples table (head lemma, relation, dependent lemma, frequency, position pointers)
in our own store, compute logDice ourselves. Fast at any corpus size and engine-independent, but
drill-down to concordance needs Manatee-side positions or pando anyway, and tree queries are lost.
Phase A should quantify whether pando's `dcoll` is fast enough on big corpora to make this unnecessary.

## Phase A results (measured 2026-09-30)

Setup: pando `main` at `8952b6d` (37 commits), built with CMake 4.4 + Ninja from a pip venv, on an M-series
Mac (32 cores, 512 GB RAM, macOS 27, Xcode 27), in `~/Developer/pando-spike/` outside the repo. macOS 15
checks ran in the existing Tart VM (15.7.7, 4 cores). Real data: UD English-EWT (255k tokens, real
parses). **Large data is synthetic**: Zipfian lemmas (vocabulary 1M), sentences of ~20 tokens, random
trees, 30 relation labels, 10 POS. It tests engine scale, not linguistic realism; real corpora will differ
in selectivity. All timings are warm-cache (files just written, 512 GB RAM): **cold-cache numbers were not
measured** (`purge` needs root).

### Build and platform
| Check | Result |
|---|---|
| Clean build (62 targets) | ~11 s, 1 warning, no changes needed |
| Default deployment target | macOS 27 (`minos 27.0`), so a release build must set `CMAKE_OSX_DEPLOYMENT_TARGET=15.0`; with it, it builds cleanly and the CLI runs on the macOS 15.7.7 VM |
| Shared lib (`-DPANDO_BUILD_SHARED=ON`) | `libpando.dylib`, 1 MB, depends only on libc++/libSystem, exports the 6 `pando_*` functions |
| Bundled test binaries | 3 of 4 pass; `mv_stage1_executor_test` fails (`parallel_matches.size() == 1u`, line 136); `cwb_dialect_test` prints nothing (exit 0) |

### Indexing and scale (synthetic corpora, single process)
| Corpus | Index time | Peak RSS | Index size |
|---|---|---|---|
| EWT 255k tokens (real) | 0.4 s | 144 MB | 15 MB |
| 10M tokens | 8 s | 457 MB | 477 MB |
| 100M tokens | 90 s | 2.0 GB | 4.2 GB |
| **1,000M tokens** | **14.7 min** | **18.4 GB** (footprint 7 GB) | **41 GB** |
Roughly linear: ~1.1 M tokens/s and ~41 bytes per token with 7 attributes plus dependencies. (Manatee's
SYN2025 index is 7.4 GB, but has different content and token count, so this is not a like-for-like size
comparison.) Index build must run on a machine with ~20 GB free RAM at 1B tokens.

### Query latency (warm)
| Query | 10M | 100M | 1B |
|---|---|---|---|
| `[lemma="l5"]` (1.3% of tokens), 5 hits + total | 0.03 s | 0.08 s | 0.70 s |
| rare lemma | 0.02 s | 0.03 s | 0.12 s |
| `[lemma="l3"] > [upos="NOUN"]` (dependency) | 0.03 s | 0.11 s | 1.06 s |
| `[lemma="l40"] >> [lemma="l7"]` (descendant) | 0.04 s | 0.17 s | 1.72 s |
| noun with `child nsubj` and `child obj` | 0.18 s | 1.7 s | 20.4 s |
| `dcoll nsubj by lemma`, very frequent node (13M hits) | 0.08 s | 0.64 s | 7.3 s |
| `dcoll nsubj by lemma`, mid-frequency node | - | - | 0.13 s |
| `coll by lemma`, very frequent node | 0.09 s | 0.64 s | 7.9 s |
| `count by form`, 13M hits | 0.03 s | 0.06 s | 0.41 s |
Conclusion: interactive at 100M tokens for everything measured; at 1B tokens interactive for selective
queries and single-relation collocations, seconds for very frequent nodes, ~20 s for multi-child tree
restrictions over all nouns. A full word profile is one `dcoll` per relation: ~10 relations x <1 s for
typical lemmas, up to ~1 min for the most frequent lemmas at 1B tokens.

### C API (`libpando`) - works, with three problems
- Works: `pando_info`, `pando_query` (hits with context, per-token attributes, exact totals),
  `pando_run` (programs: `count`, `dcoll`, ...), named-query session state persists across `pando_run`
  calls on one handle, bad queries return `{"ok":false,...}`, a missing corpus returns NULL. JSON is rich
  and well structured. Four threads with four separate handles: 800/800 queries on macOS 27.
- **Bug: the relation argument of `dcoll` is dropped through the API** (`"relations": []`; `obj`,
  `nsubj` and none all return the same list), while the CLI honours it. So the engine logic is in the CLI
  (`query_main.cpp`, 174 KB) and the API layer lags behind it. Word profiles through the API are blocked
  until this is fixed (or we shell out to the CLI/`pando-server`).
- **Bug: `pando_open` fails under concurrent opens when the file-descriptor limit is low.** Pando keeps one
  file descriptor open per index file for the lifetime of the mapping (79 for the tiny EWT index; large
  corpora have many more). macOS's default soft limit is 256, so on the VM 4 concurrent opens failed in
  most runs; after `ulimit -n 4096`, 48/48 passed. A GUI app can raise its own limit, but mmap does not
  need the descriptor after mapping, so this is an easy upstream fix.
- Minor: errors carry no message (`"query execution failed"`), and the option keys for `pando_run` are not documented (I did not establish which are honoured).

### Query-language compatibility (24 Manatee/KonText-style queries, native and `--cql cwb`)
Works in both: `[form="x"]`, `[lemma=..]`, `&`, `|` inside `[ ]`, regex, `{m,n}` on `[]`, `!=`, `%c`,
top-level named tokens with `::` (native only). `[word=..]` is accepted (aliased to `form`).
Fails or differs, in native and (more so) the CWB dialect:
- `within <s/>`, `within <doc/>` (Manatee/CQP XML-tag syntax); pando uses `within s`. `<s> [..] </s>` returned
  **0 hits silently** instead of an error.
- Parenthesised groups with repetition `([..] [..])+` and `{1,2}`: error in both.
- `containing` with a token pattern (pando: `within s having [..]`); `1:`-style numeric labels with
  Manatee's `&` global constraints; `!( ... )` negation; top-level `|` between sequences (CWB dialect only).
- Attribute names differ (`form`, `upos`, `xpos`, `deprel`, `feats` instead of `word`, `tag`).
So the CWB dialect does not make KonText-style queries portable; the app would need a pando-specific
query mode, and saved queries would not transfer between engines.
Minor quirk: `a.form` in `count M by a.form` resolved to the `contr` region's `form` attribute and returned 0
groups on EWT (works with `a.lemma`, or plain `form`); attribute names collide with region attributes.

### Word-profile prototype (real parse, EWT), one `dcoll` per relation
- `eat` (VERB): `nsubj` he, people, they, I, you, we; `obj` hay, grain, meat, cream, food; `obl` Miramar,
  restaurant, hand. `book` (NOUN, `deprel="obj"`, `dcoll head`): write, read; `book` heads: write, author,
  read. Linguistically sensible with no grammar written.
- Limits seen: (1) the `freq` column is the collocate's corpus-wide frequency, not the frequency of the
  relation triple, so logDice differs from Sketch Engine's per-relation score; (2) prepositional relations
  (obl + case marker) and coordination need extra work; (3) one query per relation, no single-pass
  profile. A comparison against Sketch Engine itself was **not done** (no access from here); it remains a
  to-do for someone with an account.

### Not tested
`pando-server` (HTTP); subcorpus-style restriction on a text attribute at 1B; cold-cache latency; concurrent
queries on one handle; real parsed Czech data at scale; memory use while serving (mmap, so shared with
the OS cache); cancellation (no API for it: a query cannot be interrupted).

### What the results change
- **Scale is not the blocker I feared**: indexing is linear, and 1B tokens is queryable with the commodity
  operations Korpora needs. This removes the main reason for "not now" in the full-replacement discussion,
  but not the others (feature parity, format stability, single author).
- The blockers for word profiles are small and fixable upstream (API drops the `dcoll` relation, fd-per-file),
  and the author is a colleague.
- No cancellation and no subcorpus object remain design gaps for a full replacement; for a second engine
  they are acceptable (disable the feature per engine).
- Waiting for pando to mature is reasonable: the file format may change (each change means re-indexing
  large corpora), the API lags the CLI, and one test already fails. A sensible order is: report the two
  bugs upstream now, keep the spike scripts, and start Phase B (engine seam), which is useful regardless,
  while pando matures. Phase C/D after the author confirms format stability.

## Phase B (engine seam) - done 2026-09-30

No behaviour change; the app now talks to an engine through protocols.
- New SwiftPM target `CorpusEngine` in the ManateeKit package (also a library product): the engine-neutral value
  types (`KWICLine`, `CorpusInfo`, `SortCriteria`, `PNFilterSpec`, `CollocationSpec`, `FrequencyCriterion`, ...)
  moved out of ManateeKit, plus the protocols `CorpusHandle`, `ConcordanceHandle` (both actors) and `CorpusEngine`
  (`id`, `openCorpus`, `openConcordance`). `ManateeKit` re-exports it, so `import ManateeKit` still works everywhere.
  Manatee's own grammar for sort/frequency criteria stayed in ManateeKit (`ManateeGrammar.swift`).
- `Corpus` and `LiveConcordance` conform; `ManateeEngine` is the implementation (`openCorpus`, `openConcordance`).
  Subcorpora open through `openSubcorpusHandle(atPath:)`.
- App: `ConcordanceDocument` holds `any CorpusHandle` / `any ConcordanceHandle` and has an injectable `engine`
  property; all seven direct `Corpus(name:)` call sites (sheets, popovers, completion) go through `Engines.default`.
  `Engines` also resolves an engine by id.
- Saved `.corpconc` documents now carry `formatVersion` (2) and `engine` (`"manatee"`); version-1 files read as
  Manatee, a newer format or an unknown engine is refused with a clear message instead of a half-read.
- Tests: ManateeKit 112 -> 119 (protocol-only tests, foreign-handle rejection); app 160 -> 169 (a scripted fake
  engine drives `ConcordanceDocument` end to end without Manatee; document-format tests). No existing test changed.
- **Left for Phase C, deliberately**: the query language (CQL colouring/completion, `SubcorpusRestriction`), the
  corpus list and import (`CorpusLibrary`, `CorpusRegistry`, `CorpusImporter`, registry files), subcorpus storage
  (`SubcorpusStore`), and per-engine capability flags for features an engine lacks (sort, line groups, cancellation).

## Update 2026-11-03: pando v0.4.1 (151 commits after the spike's `8952b6d`)

Re-checked by rebuilding `v0.4.1` (125 targets, builds in the same venv; it now wants RE2 for fast regex, I built
with `-DPANDO_USE_RE2=OFF` rather than install it) and rerunning my reproductions.

**Fixed since the spike (all verified):**
- `dcoll REL` through the C API now honours the relation (`"relations": ["obj"]`, different lists for `obj`/`nsubj`).
- `pando_open` holds no file descriptors after mapping: 8 of 8 handles open under `ulimit -n 256` (was 3 of 8).
  `pando_last_error()` says why an open failed.
- **Cancellation exists**: `pando_cancel(handle)` from another thread; the call then returns
  `{"ok":false,"error":"query cancelled","cancelled":true}`. Also `timeout_ms`, and background counts with jobs and `/cancel`.
- `a.form` after `count M by` works (60/21/13% book/booked/books); `mv_stage1_executor_test` passes; ~15 test binaries.
- **`--cql manatee`**: a real Manatee CQL dialect (replacing the thin CWB subset): `within <s/>` works, `!( ... )` works,
  aligned corpora `A within ces: B`. Still unsupported: `containing` with a query, `within s having [..]` (native only).
  Correction of my earlier note: `<s> [lemma="cat"] </s>` returning 0 was right (it means a one-token sentence; `<s> [] </s>`
  gives 772); that was not a bug.
- **Result-format contract**: every JSON answer carries `format_version: 1`, documented in `wiki/Result-Format.md` and `contract/`.
  Indexes record `indexed_with` and old indexes upgrade (`upgraded_with`); versioned index directories with atomic hot swap.
  This answers much of my format-stability worry: formats are now versioned, though at v0.x they can still change.
- Embedding: `server_capi.h` (`pando_server_*`) exposes the whole HTTP API in-process (sessions, jobs, caches, per-request
  limits); designed for hosts such as FQS (a federation/query server that already embeds pando and Manatee side by side) and
  for TEITOK/KonText. pando-server handles load (listen backlog 256).
- New features beyond what we tested: relation layers (enhanced UD `deps`, derived layers), equivalence layers and aligned
  queries with paging, dependency collocations over layers, keyness, `stats`, date functions, `tabulate`, R/Python tooling.
- An engine benchmark page (`wiki/Engine-Benchmark.md`) compares pando with Manatee, CWB, BlackLab, PML-TQ and others
  (work in progress, by the author; not re-run by us).

**Measured again (100M synthetic tokens, same generator as before):** index 85 s (was 90 s), but **5.9 GB** (was 4.2 GB) and
4.4 GB peak RSS (was 2.0 GB); queries 0.03-0.2 s (the multi-child tree query that took 1.7 s now 0.07 s, `dcoll` 0.08 s, `coll`
0.19 s). The 1B-token index was not rebuilt (it would be ~58 GB). Index growth comes from new `head#...`/`dep.pair.*` postings.

**Still open:**
- **No license** (`README.md` still says private/experimental) - the author is a colleague, so it is paperwork.
- Persistent **subcorpus objects** do not exist (named queries and `within`/region filters remain the model).
- Version is v0.4.x: the API is plausible to embed now, but the CQL dialect, option keys and index layout still move weekly.
- New build dependency (RE2 for fast regex) matters for our static, signed bundle: it would have to be built from source
  (with abseil) like pcre2 is today.
- Wiki claims ("intended behavior") still outpace tests for some features; we have not tested the new layers or aligned queries.

**What this changes:** the blockers I listed as "small and fixable upstream" were fixed within about a month, and cancellation
- the largest design gap for an engine seam - now exists. The calculus for Phase C moves from "wait for it to mature" toward
"worth a prototype": the engine seam (Phase B) already fits `pando_open`/`pando_run`/`pando_cancel`. Remaining reasons to wait are
the license, subcorpora, the RE2/abseil bundling work, and CQL churn. A reasonable next step is a thin `PandoKit` prototype that
runs KWIC, `count` and `dcoll` through `libpando` behind the `CorpusEngine` protocols, as a spike branch, not shipped.

## Lessons from FQS (`ufal/fqs`, studied 2026-11-03) and the remote backend

FQS is a Rust server (Linux, systemd) over several engines: one HTTP API, a SQLite corpus catalogue, a query queue, a
CLARIN-FCS endpoint, an admin UI, KonText and TEITOK front ends. Pando runs in-process through `libflexicorp_pando`
(a versioned C ABI: `api_version` 2-5, symbols optional by version, found by search path, `/health` says which mode is
in use); Manatee runs through its own C++ shim `libfqs_manatee`. We do **not** route the app through it, but its Manatee
handling holds lessons that apply to us regardless of engine:
- **Crash isolation.** Manatee can SIGBUS/SEGV on a wrongly read corpus. FQS runs it in worker processes, restarts a dead
  worker, kills a query that runs too long, and *quarantines a corpus that crashed twice within 10 minutes* with a message
  saying why. Korpora runs Manatee in-process, so a bad corpus takes the app down. Worth doing for both engines
  (a helper process per engine, XPC or a pipe).
- **Corpus check before the first query** (`fqsm_check`): for every positional attribute, read a few lexicon words back
  through the index and compare, and read the last position. A registry that names the wrong layout then fails with a
  clear message instead of wrong text or a crash. Our import/"Add corpus" paths would benefit.
- **Totals vs pages**: count once, remember the total (10 min), and walk later pages only to the end of the page; whole
  results are not kept (33M hits is ~0.5 GB of positions). Relevant to 6.11 pagination.
- Defensive plumbing: every C++ exception is caught in the shim; answer lines carry a marker because the library may print
  to stdout; one lock per corpus handle; optional library with a clear "unavailable" status instead of a hard failure.
- Licensing note: `libfqs_manatee` links manatee-open, so it is GPL-2; keep this in mind for how Korpora links engines.

**Future feature: a remote Korpora backend.** A third engine behind the same `CorpusEngine` protocols that talks to an FQS
server (its HTTP API, or FCS) instead of a local index: browse the server's corpus catalogue, run queries, page KWIC, get
counts/frequencies, with the corpora and compute on UFAL's side. This opens the billion-token corpora to a laptop, and the
same protocol seam (Phase B) is what makes it possible. Open points for when it is taken up: FQS's HTTP API surface and
authentication tiers, what operations map (sort/filter/line groups probably not), whether FQS keeps open concordance
handles (it exposes query-and-page, not a live handle), latency and offline behaviour, and how saved documents name the
server and corpus. Not started.

## Phase C spike: PandoKit (branch `spike/pando-engine`, 2026-11-03)

`PandoKit` is a `CorpusEngine` over `libpando`, in the ManateeKit package (a product of its own, pure Swift).
- **Loading:** `dlopen` at run time (`PandoLibrary`), no build-time dependency: `$KORPORA_PANDO_LIB`, then the app's
  Frameworks folder, then `/usr/local/lib`; a missing or too-old library gives a clear error, like FQS's "unavailable" mode.
  Uses `pando_open/last_error/cancel/query/run/info/close`.
- **Implemented:** open a corpus (index directory under a root, or an absolute path), schema (`CorpusInfo` from `pando_info`),
  query + KWIC (match tokens with attributes, context from pando's context strings; `word` maps to `form`), total, collocations
  (`coll`, all six measures mapped), frequency distributions (`count by`), attribute values (`show values`, regex "matching"
  filtered client-side), cancellation (`pando_cancel` from the task's cancel handler; checked again afterwards because pando
  drops a cancel that arrives before the call starts), engine-handle per concordance (cheap now that handles hold no fds).
- **Not available** (throw `PandoError.unsupported` with the feature named): sort, filter, shuffle, sample (pando's sampling is
  CLI-side), line groups, subcorpora, the dispersion plot, extended context (no structure-at-position lookup via this API).
  `EngineCapabilities` (new, in `CorpusEngine`) lists what an engine can do; the UI wiring that greys controls out is still to do.
- **Limits of the spike:** context tokens carry no secondary attributes (pando returns plain strings; its `fragment` option could
  fix that), structure contexts such as Bonito's `-1:s` fall back to 10 tokens, and corpus naming/discovery is a bare directory.
- **Tests:** 12 `PandoEngineTests` (build a two-sentence index with pando's own `pando-index`, then drive everything through the
  protocols; skip without `KORPORA_PANDO_LIB`) and 2 app tests running a real `ConcordanceDocument` against pando
  (`TEST_RUNNER_KORPORA_PANDO_LIB=... xcodebuild test`), including an unsupported operation (shuffle) showing a clear status.
  Everything passes (app 171 with the pando tests, 3 runs; ManateeKit 120 + 12).

**Two Manatee concurrency bugs the engine seam exposed, both fixed on `main`** (the second is older than the seam):
1. Phase B made `openCorpus` async, so corpora opened on the cooperative pool instead of the main thread, and overlapping opens
   corrupted Manatee's heap: the app test suite crashed in `Corpus::~Corpus` in ~1 of 4 runs (0 of 12 at v0.3). Opens now go
   through one actor (`OpenGate`); 12 of 12 clean after, plus 6 with pando loaded.
2. Manatee's CQL parser keeps state in globals, so concurrent searches could fail with "unexpected end of file" on a valid query
   (two windows searching at once could hit this in v0.3 too). The bridge now serializes only the parse step; evaluation still
   overlaps. A 24-task stress test fails 3 of 3 without the lock and passes with it.
   Takeaway: any engine behind the seam must be assumed single-threaded unless proven otherwise; FQS's per-corpus lock and
   crash-isolated worker processes are the same lesson.

**What the spike says about the decision:** the seam fits. A second engine needed ~400 lines of Swift, no change to the app's
document code, and the protocols were enough for KWIC, analyses and cancellation. The cost is in the gaps: operations pando
lacks (sort, filter, line groups, subcorpora) are most of what makes Korpora's concordance window useful, so a pando corpus
would be a read-mostly experience until pando or the app fills them. Next steps if we continue: wire `capabilities` into the
toolbar and menus, corpus discovery/"Add pando corpus" in Settings, a pando-aware query field (CQL colouring and dependency
operators), `fragment` for secondary attributes in context, and the dispersion plot via a pando position query.

## GUI integration: pando corpora treated like Manatee corpora (analysis 2026-11-03)

Question: if a pando corpus is simply another corpus in the app, what is different, apart from new query-language options
(and without trees)? Method: every GUI feature checked against the code (what it asks of the engine) and against what pando
offers (tested on its sample index, plus its wiki). Verdicts: **OK** works as is; **ADAPT** works after app work, no pando
change; **UPSTREAM** needs something from pando; **GAP** not available at first.

### Corpora and Settings
| Feature | Verdict | Notes |
|---|---|---|
| Corpus list in the New Concordance sheet | ADAPT | Built from Manatee's registry (`CorpusRegistry`); needs one list with an engine tag per corpus. A pando corpus is an index directory (`corpus.info`), not a registry file; the same name may exist in both engines, so identity is (engine, name). |
| Settings > Corpora (Source column, add, remove, Keep in Memory) | ADAPT | "Add existing" = pick an index folder (linked, like added registry files); remove keeps/deletes the folder; Keep in Memory = pando's `preload` at open (the residency manager reads Manatee data files, engine-specific). |
| Import a corpus | ADAPT / GAP | Manatee: vertical file via `encodevert`. pando indexes CoNLL-U/JSONL (`pando-index`), not verticals. A "Import UD/CoNLL-U" sheet is natural; a generic vertical would need our own vertical-to-JSONL converter. |
| Corpus info, attribute lists | ADAPT | From `info()`, works, but **attribute names differ** (`word/lemma/tag` vs `form/lemma/upos/xpos/deprel/feats`) and `"word"` is hard-coded in 6 places (default KWIC attribute, attribute popover, sort popover, column-header sort). Needs a per-corpus default attribute in `CorpusInfo`. |
| Subcorpora (create from the value picker, choose per search, `.subc` files) | ADAPT | pando has no subcorpus object, but its global filters (`:: match.text_genre = "Book"`) express the same thing: a subcorpus becomes a saved restriction (our `SubcorpusRestriction` is already that model) appended to every query. Value counts for the picker come from `show values`; subcorpus size for the status line / per-million needs a computation. Verify that region-value counts mean documents, not tokens. |

### Searching
| Feature | Verdict | Notes |
|---|---|---|
| Run a query, KWIC table, status line, hit totals, cancel with Cmd-. | OK | Tested through `ConcordanceDocument` (`pando_cancel`; only a pre-cancelled task is tested, not a long running one). Counts follow pando's semantics (default `within`, sequences across sentences) and can differ from Manatee on the same data. |
| Left/right context in tokens; sentence view (`-1:s`) | ADAPT | Tokens work. The sentence view needs pando's `sentence` option (the wrapper currently falls back to 10 tokens). |
| Inline attributes and tooltips on **context** tokens | UPSTREAM | pando returns context as plain strings; only the match tokens carry attributes. Its `fragment` option (XML with every attribute) has them but is server-side and wasn't returned by the plain C API in my test. |
| Structure column per hit ("doc.title"), Extended Context header | ADAPT / UPSTREAM | The app looks up "structure attribute at corpus position". pando has no such call; region attributes of *hits* are available through `tabulate M a.text_genre` (works). Needs a per-hit lookup API in the protocol, or a small upstream `region at position`. |
| Extended Context window (wide context for one hit) | ADAPT | Fetch that hit again with a large `context` (`offset=row, limit=1`), or pando's `/context?pos=` through the embedding API. |
| Sort (attribute, left/right/kwic, span, case, retrograde, up to 4 levels) and header-click sort | ADAPT, uncertain | pando has `sort M by att [%c|%d] [on from..to]` (levels and ranges, but mapping of left-context ranges, retrograde and whether a sort affects later paging through `pando_query` is untested). Fallback: sort the fetched lines in the app (we already hold all lines). |
| Shuffle, Sample | ADAPT | pando has `--sample` (CLI); neither is in its API options. Since the app already loads every hit, both can be done client-side for any engine. |
| Positive/negative filter ("keep lines where this query matches within -5..+5") | GAP | Manatee-specific (`set_collocation`); no pando equivalent. Grey out first. |
| Line groups (assign, filter by group, Operations popover) | ADAPT | Today stored inside Manatee's concordance. They are just labels on lines, so they can live in the document for any engine. |
| Operations chain, undo/redo, history | ADAPT | The chain replays operations on a fresh result; it must hold engine-neutral operations (client-side ones) and be told which the engine supports (`EngineCapabilities`, exists, not wired yet). |

### Analyses and display
| Feature | Verdict | Notes |
|---|---|---|
| Collocations (+ table/chart) | OK | Tested; the measures map. Scores are the same family but not guaranteed identical to Manatee's (not compared). |
| Frequencies by attribute, by structure attribute with normalised value | OK / ADAPT | Attribute counts work. Structure attributes (relative to subcorpus size) come back in a different shape (`rf_pct`, `subcorpus_size`); mapping needed. Frequency of a token at an offset is not mapped. |
| Dispersion plot | ADAPT | Needs hit positions: fetch positions (`raw`) and bin them in the app; fine up to a few million hits; an upstream histogram would be better. |
| Print, export CSV/TSV, charts, headers | OK | Engine-independent (export loses context attributes, as above). |

### Language and documents
| Feature | Verdict | Notes |
|---|---|---|
| Query field: colouring, completion, auto-pairing | ADAPT | Strings, brackets and attribute names carry over; keywords and operators differ (`within s`, `>`/`<`, `child[..]`, `::`). Needs a per-engine language profile. pando's `--cql manatee` dialect lets existing Manatee-style queries run (`within <s/>`, `!(..)`), but it is partial (`containing`, labels), so the choice should be visible to the user. |
| Query history | ADAPT | Keyed by corpus name only; needs the engine in the key. |
| Saved `.corpconc` documents | OK / ADAPT | Carry the engine id already; they must resolve (engine, name) in the unified corpus list, and a subcorpus path becomes a restriction. |

### Not engine-specific but affected
- **Everything is fetched at once**: the app loads KWIC lines for all hits. That already limits Manatee; pando's JSON for millions of hits is worse. Pagination (plan item 6.11) is a prerequisite for large pando corpora and fits pando's native paging.
- **Packaging**: libpando in the app bundle (signed and notarized), a build step for it (and for RE2 plus abseil if we want fast regex), and its licence.
- **Threading**: pando handles are one per concordance (fine); Manatee's two concurrency bugs were found via this seam, so any new engine should get the same stress test.

### Summary
- Works with no app change beyond what exists: querying, KWIC, cancel, collocations, frequencies, charts, print and export.
- Works after app work and no pando change: the unified corpus list and Settings, default attribute names, sentence view, Extended Context, structure column (via tabulate), sort/shuffle/sample (client-side or pando `sort`), line groups (client-side), subcorpora (as restrictions), dispersion, per-engine query-language profile, history and document keys.
- Needs something from pando, or is lost at first: context-token attributes, positive/negative filter, position-to-region lookup (workaround exists), vertical import.
- Most of the "ADAPT" rows share one idea: a **client-side operations layer** over a plain "query + page" engine (sort, shuffle, sample, line groups, filter on loaded lines). It is also exactly what a remote FQS backend would need, so it is the one piece worth building for both.

## Direction under discussion: pando as the only engine, and a one-stop corpus workshop (2026-11-03)

Status: **proposal, not decided.** The owner is inclined to switch fully (experimental app, bleeding edge is acceptable) if it
simplifies both the code and the user experience, and to add a first-class "corpus workshop": plain text and documents in,
searchable parsed corpus out, in one easy Mac UI.

**The UFAL "Flexi" stack, which makes the workshop possible (checked 2026-11-03):**
- `flexiconv` (MIT, Python library + CLI + a desktop GUI): converts between many formats through a TEI/TEITOK pivot. Reads txt, md,
  html, rtf, docx, odt, pdf, epub, OCR layouts, spoken-corpus formats (eaf, textgrid, srt, chat), `conllu`, `vert`, TEI; writes
  TEITOK TEI, among others. Also deduplication.
- `flexipipe` (no licence yet; Python): raw text or CoNLL-U to Universal Dependencies (tokenize, tag, lemmatize, parse) through
  pluggable backends (UDPipe, spaCy, Stanza, Flair, its own C++ `flexitag`); models from `flexipipe-models` (UDPipe models are CC BY-NC-SA).
- `flexencoder` (no licence yet; C++): TEI to pando index (linked against pando's C++ API, or JSONL piped to `pando-index`), also
  Manatee VRT and CWB. `flexicorp_pando`: pando plus xidx (byte offsets into the source XML, for showing original text).
- pando itself reads CoNLL-U and JSONL directly (`pando-index`), so the minimal chain is:
  `document -> flexiconv -> text/TEI -> flexipipe -> CoNLL-U -> pando-index -> corpus`.
Open facts: whether flexiconv's txt output needs flexipipe for tokenisation; how large an embedded Python plus neural models
would be (models are the real cost); the licences of flexipipe and flexencoder; the state of flexiconv's desktop app (only a
README in `apps/` today).

**What a full switch would remove or simplify:** the C++ bridge to Manatee (about 940 lines, 61 functions) and the manatee-open
fork with its heap-corruption patch; the pcre2 static build and the `encodevert`/`mkregexattr` helper binaries; registry files,
the compiled-corpora directory, `.subc` subcorpus storage; the Manatee thread-safety gates and a class of crash risk; GPL-2
linkage (manatee-open is GPL-2) replaced by libpando under a licence we can agree with its author. The 6-function C API is much
smaller than ours.

**What it costs or risks (to validate, not assume):**
- Existing Manatee corpora and verticals: users need a re-import path (flexiconv reads `vert`).
- Size on disk: pando's index measured 93 bytes/token (EWT, 7 attributes plus dependency postings) and 41-58 GB for a synthetic
  billion tokens, versus Manatee's 7.4 GB for SYN2025. Not like-for-like, so the decisive test is to index the *same* real
  corpus (SYN2025 via flexiconv vert -> pando) in both and compare size, build time, memory and query times.
- Feature parity from the GUI analysis above (filter, line groups, subcorpora, sort, context attributes), pagination (6.11).
- Pando is v0.4 with weekly changes, one author, no licence yet (a colleague, so paperwork).
- A Python-based pipeline inside a signed, notarized app: embedding a Python runtime and downloading models on demand, or using
  only native components (pando-index; flexitag/UDPipe if usable natively); network and licence of models.

**Staging that keeps the experiment safe:** Phase B's engine seam lets Manatee stay until pando has parity. Order: (1) validate
size and speed on the same real corpus; (2) unified corpus library UI and pando parity for what exists (see the GUI table);
(3) the workshop (import, convert, annotate, build) and a simplified UX vocabulary; (4) make pando the default, mark Manatee
deprecated; (5) remove Manatee code and its build in a later release.

## SYN2025 head-to-head, Manatee vs pando (measured 2026-11-03)

The decisive test for the full-switch direction: the same real corpus in both engines. SYN2025 (122,251,447 tokens, Czech, parsed;
29 positional attributes and 22 document attributes in the Manatee index) was regenerated from the compiled Manatee index with a
throwaway converter (our ManateeKit to CoNLL-U: word, lemma, tag as XPOS, pos as UPOS, `afun` as DEPREL, relative `parent` offset to
absolute HEAD, enhanced parent as DEPS, the rest as FEATS; 3,943 documents with all 22 attributes; 7,743,026 sentences) and indexed
with pando v0.4.1. Same Mac (M-series, 512 GB RAM, macOS 27), warm caches, pando via its CLI (so its numbers include ~0.1 s of
process start), Manatee in-process through ManateeKit.

| | Manatee | pando |
|---|---|---|
| Tokens in the index | 122,251,447 | 122,251,447 |
| Index size on disk | 7.0 GB (29 attributes) | **11 GB** (6 attributes + dependency/head postings, 22 document attributes) |
| Build | (original import took far longer; not re-measured) | **147 s**, 6.4 GB peak RSS (2.8 GB footprint), from 12 GB of CoNLL-U |
| Conversion from the Manatee index to CoNLL-U | n/a | 30 min (our throwaway tool, single-threaded) |

Query hit counts: **identical in all 8 comparisons** (frequent lemma 3,978,146; mid 86,892; rare 2,088; two-token sequence 98;
regex 70,701; lemma plus tag 19,665; noun-verb 3,977,043; restricted to a document type 54,597).

| Query | Manatee | pando |
|---|---|---|
| frequent lemma (4.0M hits) | 0.81 s | 0.11 s |
| mid / rare lemma, sequence, regex, tag filter | 0.02-0.05 s | 0.11-0.19 s (process start included) |
| noun followed by verb (4.0M hits) | 1.21 s | 0.12 s |
| restricted to a document type | 0.02 s | 0.11-0.20 s |
| collocations, lemma "ruka" | 0.42 s | 0.22 s |
| frequency by tag / by document type | 0.07 s / 0.01 s | 0.12 s / 0.12 s |
| all 86,892 KWIC lines | 0.97 s | 0.25 s |
| verb with subject and object children (2.6M hits) | not expressible | 0.27 s |
| dependency collocates of "ruka" | not expressible | 0.21 s |

Reading: for small result sets the engines are indistinguishable in practice (pando's 0.1 s is mostly process start); for large
ones pando is faster, up to 10x; dependency queries come at no extra cost. The disk size is the one regression (+57%), and it would grow
with more attributes; not a problem for the target use (a laptop with a few corpora), worth stating to users.

Document metadata: all 22 attributes arrive as `doc_*` region attributes and are queryable (`:: match.doc_txtype = "..."`, `count
by a.doc_txtype`) **only** when written with `# newdoc id = ...` plus `# meta::KEY = value`. The CoNLL-U `# text_KEY = value` route
silently drops every value that contains a space (found in `is_simple_region_value`, `src/corpus/builder.cpp`): author, title, biblio and
most of the others vanished in my first attempt. To report upstream: warn instead of dropping; document `meta::`.
Other data notes: pando warns about 72,388 tokens whose head lies outside their sentence (stored as roots) and marks the
head relation "not a tree" for the 7.2M sentences with several roots (this corpus' annotation attaches fragments and final
punctuation to the root); queries on it work. Structures `block`, `g`, `hi` were not carried over.

Verdict: the "scale and fidelity" risk to a full switch is retired for this corpus size: same answers, faster, bigger on disk. Still
untested: billion-token real corpora, cold caches, and the GUI-parity items listed earlier.

## Recommendation

Do **not** replace Manatee. Run Phase A now (a few days of work, no risk), decide from its numbers.
If scale and FFI hold up, do B → C → D. If pando fails on large corpora, keep it for treebank-scale
corpora only, or take the triples-table fallback for word profiles.

## Critical files (for the follow-up implementation, not for this analysis)

- `ManateeKit/Sources/CManatee/include/mtcbridge.h`, `mtcbridge.cc` — bridge to mirror for FFI
- `ManateeKit/Sources/ManateeKit/ManateeKit.swift`, `LiveConcordance.swift` — types to abstract
- `Korpora/Korpora/Documents/ConcordanceDocument.swift` — main coupling point, persistence at ~691–757
- `Korpora/Korpora/Views/CQLQueryField.swift`, `CQLCompletion.swift` — language front end
- `ManateeKit/Sources/ManateeKit/CorpusLibrary.swift`, `CorpusRegistry.swift`, `CorpusImporter.swift` — corpus list/import
- `scripts/build-release-deps.sh`, `scripts/make-release.sh`, `Korpora/project.yml` — release plumbing
- Reusable for the profile UI: `Views/BarChartView.swift`, `PaperSafeDrawing.swift`, `WindowPrinting.swift`

## How the claims here were checked

- Every pando claim in the write-up is sourced from the repo files above (`README.md`, `wiki/*`,
  `src/api/pando_ffi.h`) or measured in Phase A; unknowns stay marked as unknown.
- Coupling table cross-checked against the Explore report and `docs/project-plan.md`.
- Phase A results table filled with measured numbers before any go/no-go is stated.
