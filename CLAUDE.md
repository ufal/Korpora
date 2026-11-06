# Korpora

`Korpora` is the native AppKit macOS app: a corpus workshop and concordancer on top of
[pando](https://github.com/ufal/pando) (the corpus query engine from UFAL), which it loads at run time
(`dlopen`) through its C API. `KorporaEngine` is the engine layer: the protocols the app talks to
(`CorpusEngine`, `CorpusHandle`, `ConcordanceHandle`), the pando implementation, the corpus library,
import (`pando-index`), and subcorpora. The app used to sit on Manatee (the engine behind KonText);
that integration is gone (docs/pando-gui-plan.md). It was renamed
from Corpora to Korpora, directories included, so the project lives at
`Korpora/Korpora.xcodeproj` with sources in `Korpora/Korpora/` and tests in
`Korpora/KorporaTests/`. Every "Corpora" that meant *the app* is gone;
"Corpora" as the plural of *corpus* — the Settings tab,
`CorporaSettingsViewController` — is correct and should stay.

## Project plan

`docs/project-plan.md` is the living status/handoff document for this
project — read it before starting non-trivial work, and update it as part
of the work rather than after. It was written in the Manatee era and is being brought up to date;
`docs/pando-analysis.md` (why pando, with the measurements) and `docs/pando-gui-plan.md` (how the app
moved to it) are the current design notes.

Project plans and design notes belong in `docs/` inside this repo. Never
write them to `~/.claude/plans/` or another location outside the checkout —
they need to survive across sessions and machines, and code comments cite
them by repo-relative path.

## Division of labor

- **Terminal Claude Code sessions**: engine-layer work (`KorporaEngine`),
  tests, AppKit *code* changes, git/PR work, planning.
- **Xcode's built-in Claude agent**: building/running `Korpora.app`,
  visual inspection, interactive click-through testing, iterating on
  layout/visual polish — via its `BuildProject`/`RunAllTests`/
  `DeviceInteraction*` tools.

## Repos and setup

- `KorporaEngine/`, `Korpora/`, `scripts/` — this repo
  (`github.com/ufal/Korpora`, renamed from `mac-corpora` along with the
  app). The local checkout directory is `korpora/`.
  - **The bundle identifier is `cz.cuni.mff.ufal.korpora`** (since the
    first release; it was `cz.cuni.mff.ufal.mac-corpora.dev` before).
    Don't change it again: it's a live identifier, not a name —
    `UserDefaults` is keyed by it, and so are notarization and
    Gatekeeper's view of the app. Settings from the old id are carried
    over once at launch by `LegacyDefaultsMigration` (called first in
    `main.swift`); keep that in place so older installs don't reset.
- pando is **not** part of this repo: `scripts/pando-spike.sh build` clones and builds
  `ufal/pando` into `~/Developer/pando-work/` (outside the checkout); `sample` and `ud` index test
  corpora there; `test` runs the engine and app tests against it. Tests that need pando skip when
  there is no build. A release bundles its own pando (`scripts/build-release-deps.sh`).
