# demo/ — a guided walkthrough

`index.html` is a self-contained, claude.ai-styled slide deck that walks the
repository step by step. Every step pairs a **Do** (the exact command to run)
with a **Check** (the output that proves it worked). Every command and every
figure in it was taken from the real scripts under `gates/`, `corpus/` and
`.claude/` — not invented for the slides.

## Open it

No build, no dependencies — just a browser:

```sh
# from the repo root
open demo/index.html            # macOS
xdg-open demo/index.html        # Linux
start demo/index.html           # Windows
```

Navigate with the sidebar, the Back/Next buttons, or the ← / → arrow keys.
The URL hash tracks the slide, so a link like `demo/index.html#6` opens on a
specific step.

## The eight steps

0. **Prerequisites** — `docker compose up -d` (mssql :11433, mongo :37017)
1. **Non-circular gate** — the oracle frozen before any model (ADR-0001)
2. **Mechanical seed** — Mongo as a pure function of the relational seed (ADR-0003)
3. **Subagents & skills** — the four Claude Code primitives (ADR-0004)
4. **The pipeline** — one procedure through four stages, each with a scoped tool
   set and a single artifact; the golden feeds three stages independently (ADR-0001/0004)
5. **The gates** — `bash gates/verify.sh` reproduces the verdict, no model (ADR-0005)
6. **In-loop hooks** — every transition gated automatically (`.claude/settings.json`)
7. **Proven teeth** — `bash gates/mutation-check.sh`, 5/5 mutants caught (ADR-0006)
8. **Retry protocol** — failures fed back, cap 2 (`pipeline/retry.md`)
9. **Measure** — the paid, opt-in headless run and honest reporting (Phase 4)

The fastest end-to-end sanity check, with no model in the loop:

```sh
docker compose up -d
bash gates/verify.sh          # build + unit + differential all green
bash gates/mutation-check.sh  # the differential has teeth
```
