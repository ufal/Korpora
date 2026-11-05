# Draft issue for ufal/pando: the C API lacks options and caching the HTTP API has (2026-11-05)

Filed as https://github.com/ufal/pando/issues/3 on 2026-11-05 (`sentence` is issue #1). Tested with pando 0.4.1 (`libpando.dylib`, macOS 27, arm64) and a UD index. Korpora (a native macOS
concordancer) embeds `libpando` through `pando_ffi.h`, so it can only use what the C API reads.

**Title:** C API: `sentence`, `shuffle`, `sample`, `seed` are ignored, and a sorted result can't be paged without
sorting again

## What works, for context
Paging by `offset`/`limit` is fast at any depth (SYN2025, 122 M tokens, a query with 3,978,146 hits: a page of 50 at
offset 3,000,000 in 149 ms; one hit at a random offset 72 ms). With that Korpora scrolls a result of any size
without loading it (the way KonText only builds the lines of the visible page). Thank you.

## What doesn't
`parse_query_opts` / `parse_program_opts` in `src/api/pando_ffi.cpp` read `limit`, `offset`, `max_total`, `context`,
`total`, `debug`, `strict_quoted_strings`, `dialect`, `attrs` (and for `pando_run` the group/coll ones), but not the
options `server_api.cpp` reads for `POST /query`:

1. **`sentence`** (sentence-bounded context). Ignored, so a KWIC/sentence view switch can't be offered.
2. **`shuffle`** (KonText's *Shuffle*: every hit in random order, paged with `offset`/`limit`). Ignored: the hits
   come back in corpus order.
3. **`sample`** (a random N of the hits, with the `"sample"` result block). Ignored.
4. **`seed`** (the same seed gives the same sample/order on every page). Ignored.
5. **Sorted paging.** `M = Q; sort M by form on matchend[1]..matchend[3]` through `pando_run` works, but it sorts the
   whole result on every call: 2.3-6 s per page for 4 M hits, also for the next page of the same sort on the same
   handle. The session keeps `M` (`show named` says `materialised`), but no statement pages it: `Last` and `M` alone
   are "Unexpected identifier". The HTTP API caches sort indexes and sorted pages (`--cache-mb`, blocks of 1024
   hits), which is exactly what a scrolling concordance needs.

## Reproduction
```c
// cc -I src/api repro_capi_options.c -Lbuild -lpando -o repro && ./repro IDX
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "pando_ffi.h"

static void positions(const char *label, const char *json) {      // "match_start" of the first hits
    printf("%-26s", label);
    const char *p = json; int n = 0;
    while ((p = strstr(p, "\"match_start\"")) && n++ < 8) { p += 14; printf(" %ld", strtol(p + 1, NULL, 10)); }
    printf("\n");
}
static void run(pando_handle_t h, const char *label, const char *cql, const char *opts, int program) {
    char *r = program ? pando_run(h, cql, opts) : pando_query(h, cql, opts);
    positions(label, r ? r : "(null)"); pando_free_string(r);
}
int main(int argc, char **argv) {
    pando_handle_t h = pando_open(argv[1], 0);
    const char *Q = "[upos=\"VERB\"]";
    run(h, "default",           Q, "{\"limit\":8}", 0);
    run(h, "shuffle (seed 7)",  Q, "{\"limit\":8,\"shuffle\":true,\"seed\":7}", 0);
    run(h, "sample 8 (seed 7)", Q, "{\"limit\":8,\"sample\":8,\"seed\":7}", 0);
    char *a = pando_query(h, Q, "{\"limit\":1,\"context\":50}");
    char *b = pando_query(h, Q, "{\"limit\":1,\"context\":50,\"sentence\":true}");
    printf("sentence changes the result: %s\n", (a && b && strcmp(a, b) != 0) ? "yes" : "NO (ignored)");
    pando_free_string(a); pando_free_string(b);
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    run(h, "sort, page 1", "M = [upos=\"VERB\"]; sort M by form on matchend[1]..matchend[3]", "{\"limit\":8,\"offset\":0}", 1);
    run(h, "sort, page 2", "sort M by form on matchend[1]..matchend[3]",                      "{\"limit\":8,\"offset\":8}", 1);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    printf("two sorted pages: %.3fs\n", (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9);
    char *r = pando_run(h, "Last", "{\"limit\":8}"); printf("paging the sorted set: %.80s\n", r); pando_free_string(r);
    pando_close(h);
}
```
Output on the full UD release (about 5 GB index; any index shows the first four):
```
default                    2 4 5 6 8 13 15 19
shuffle (seed 7)           2 4 5 6 8 13 15 19        <- expected a random order
sample 8 (seed 7)          2 4 5 6 8 13 15 19        <- expected 8 random hits
sentence changes the result: NO (ignored)
sort, page 1               5168280 10877960 ...
sort, page 2               12404966 12405211 ...
two sorted pages: 6.925s
paging the sorted set: {"ok":false,"error":"Unexpected identifier 'Last' at position 0"}
```

## Suggested change
- Read `sentence`, `shuffle`, `sample`, `seed` in `parse_query_opts` (and `parse_program_opts`) the same way
  `server_api.cpp` does, and return the `"sample"` block.
- For sorted paging, either route `pando_run` sorts through the same per-corpus cache as the server (keyed on the
  query, the sort and the options; the handle may share it), or let a named set or `Last` be paged with
  `offset`/`limit` without sorting again.
- Document the option keys each function accepts in `pando_ffi.h`.

## Why it matters
A GUI shows a result as a scrolling table. With these a result of millions of hits can be scrolled (works today),
shuffled, sampled and sorted over all hits and not just the first hundred thousand that fit in memory. Without them
Korpora sorts and shuffles only the first 100,000 hits of a big result and says so in the window.
