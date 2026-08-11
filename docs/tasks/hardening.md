# Hardening tracker — closing the review findings

Derived from three independent expert reviews of the repo (2026-08-10), read
through three lenses: a **senior AI hiring manager** (is this a real senior
signal?), a **principal MLOps/pipeline engineer** (is this how production AI
pipelines are actually built?), and a **pre-sales solutions architect** (would a
client buy "I can deploy this in your environment"?).

All three converged on one diagnosis: **the *thinking* is genuinely senior; the
*artifact* currently describes a finished multi-proc, measured system that isn't
there yet.** 1 of 14 procs is converted, the eval harness that would produce every
headline number does not exist, and CI runs none of the gates. The fixes below
close that gap.

> **Same lifecycle rule as [`README.md`](README.md).** Each row names one target
> file (or a small set). "Done" is not an opinion — the file exists and the check
> that judges it is green. When a whole tier is `done`, its exit note moves into
> the permanent doc it fixed and the table is deleted.

## Status legend

`todo` · `wip` · `blocked` · `done` · `cut` (dropped, with a one-line why)

Tiers are ordered by **ROI on the "is this professional / would I hire-or-buy"
decision**, not by effort. Tier A is minutes–hours and removes the sharpest
live-gotcha risks; Tier B is days and moves the project from "impressive design
doc" to "demonstrated result"; Tier C is what must be true before selling it as a
client-deployable capability.

---

## Tier A — Quick wins *(minutes–hours; remove the "reads as sloppiness" gotchas)*

These are near-free and disproportionately damaging if left, because the project's
single biggest asset is its honesty-under-scrutiny reputation — any internal
contradiction or committed mistake spends that credibility fast.

| # | Task | Target file(s) | Status |
|---|------|----------------|--------|
| A.1 | Fix the `byte-for-byte` misstatement | `README.md`, `gates/differential.sh`, `gates/verify.sh` | done |
| A.2 | Reconcile README "no numbers" vs demo "these are facts" | `README.md`, `demo/index.html` | done |
| A.3 | Present→future tense for the unbuilt harness | `docs/architecture.md`, `pipeline/retry.md`, `evals/PREREGISTRATION.md` | done |
| A.4 | Scope-label the demo metric tiles as "showcase proc" | `demo/index.html` | done |
| A.5 | Repo hygiene: delete committed mistakes | `corpus/_bak;C`, `.claude/hooks/guard_path.py` | done |
| A.6 | Reconcile the number/count drifts | `docs/adr/0002-*.md`, `corpus/capture-golden.sh`, `demo/README.md` | done |

**Tier A closed.** Exit notes: A.1 — the differential is now described as
value-by-value after canonicalisation everywhere it is judged; `byte-identical`
survives only in the golden *stability* check, where it is literally true. A.5 —
`_bak;C` removed; `__pycache__`/`.pytest_cache` were already `.gitignore`d and
untracked. **Correction (during B.1):** the A.5 deletion of `guard_path.py` was a
mistake and has been reverted. The two guard files are **not** duplicates —
`guard-path.sh` is the wired PreToolUse hook and its last line *delegates* to
`guard_path.py` (which holds the actual path logic). Deleting the `.py` left the
shell hook calling a missing file, so the guard would fail closed and block every
write. `guard_path.py` was restored from `fac5b64` and re-checked (allows
`generated/` → exit 0, blocks `corpus/` → exit 2). A.6 — real golden count is
**67**; ADR-0002 now carries a superseded-by-0007 annotation, and
`GetStockHoldingUpdates`' single case was left as-is (its own `notes` already
justify one case for a zero-parameter proc).

### A.1 — Fix the `byte-for-byte` misstatement
**Problem.** `README.md:91` (and the diagram around `:78`) says the differential
compares output *"byte-for-byte"*. It does not — it is **value-based after
canonicalisation**: `gates/differential.sh` pipes both sides through
`canonicalise.py` (decimals to fixed-scale strings, keys sorted), and ADR-0001
itself says "value-by-value". The demo already says "identical *after
canonicalise*". `byte-for-byte` is true only of the golden *stability* check
(`verify-stable.sh`), which is a different thing.
**Why it matters.** It over-sells the gate's strictness and is internally
inconsistent — a reviewer who reads the code catches the README lying about its
own mechanism. (hiring + MLOps + pre-sales all flagged)
**Done when.** README/architecture say "value-based, after canonicalisation" for
the differential; "byte-identical" is used only where it's literally true (golden
stability). Grep for `byte-for-byte`/`byte for byte` returns only the stability
context.

### A.2 — Reconcile README "no numbers" vs demo "these are facts"
**Problem.** `README.md:20-23` promises *"Where a number or a result would go, this
document says so plainly rather than showing a placeholder"* — and shows none. But
`demo/index.html` (~`:684`, `:779`, `:909`) presents dated, measured gate results:
*"real local run, 2026-08-10"*, the `5/5 / 5/5 / 67/67 / $0.00` tiles, and *"Nothing
here is an estimate. These are facts."* A decision-maker who reads the README first
("no numbers yet") then the deck ("these are facts, dated") sees two documents
disagreeing on whether measured results exist. These are *gate* numbers, not the
Phase-4 eval, so it is not a literal contradiction — but the postures clash.
**Why it matters.** Either the runs happened (then the README is needlessly
timid and should cite them) or the tiles were composed to illustrate (then they are
a landmine). Pick one posture. (pre-sales, upgraded to top gap)
**Done when.** One consistent stance: EITHER the README references the reproducible
gate results the demo shows (with the "run it yourself" command), OR the demo tiles
are explicitly marked as illustrative in the same voice the Phase-4 table already
uses. No reader can find the two documents disagreeing on whether numbers exist.

### A.3 — Present→future tense for the unbuilt harness
**Problem.** `evals/` contains only `PREREGISTRATION.md` — there is no
`harness.py`, `run.sh`, or `results/`. Yet the harness is narrated in the
present/definite tense: `pipeline/retry.md:69` says the cap "is enforced" in
`evals/harness.py`; `docs/architecture.md §5` says the harness "runs… records…
reports"; `PREREGISTRATION.md:15` pins "Model + version: `<model-id, dated>`" — an
unfilled placeholder, so nothing is pinned anywhere.
**Why it matters.** For a candidate whose brand is honesty-under-scrutiny, docs
that describe a running system that isn't there is the exact crack the story runs
through. The README Status line is honest; the body contradicts it. (all three)
**Done when.** Every present-tense reference to the harness reads as planned/future
until it runs (`retry.md`, `architecture.md §5`), and the `<model-id>` placeholder
is either filled or explicitly marked "to be pinned at run-001". *(If A.3 and B.3
land together, this reverts to present tense — do A.3 first so the interim state is
honest.)*

### A.4 — Scope-label the demo metric tiles as "showcase proc"
**Problem.** `demo/index.html` metric tiles (`~:909-912`) and recap (`~:960`) show
`5/5` correctness, `5/5` mutants, presented as an end-to-end, corpus-wide guarantee.
`gates/differential.sh` and `mutation-check.sh` both hardcode
`PROC="Website.SearchForCustomers"`; only 1 of 14 procs has a generated service. A
fast reader reads the tiles as "the whole corpus passes".
**Why it matters.** Reading a single-proc result as corpus-wide is the kind of
over-claim that, once noticed, retroactively discredits the honest parts.
**Done when.** The tiles/recap carry a one-word scope marker ("showcase proc" /
"1 proc") so no reader mistakes them for a corpus-wide metric. Cheap; protects the
honesty asset.

### A.5 — Repo hygiene: delete committed mistakes
**Problem.** Three "browsing reviewer will notice" tells:
- `corpus/_bak;C` — a directory literally named with a stray `;C`, a committed
  shell mistake.
- Two guard-hook implementations coexist — `.claude/hooks/guard-path.sh` **and**
  `guard_path.py` — only one is wired; the other is an iteration remnant. **Verify
  which one `.claude/settings.json` actually references before deleting the other.**
- `__pycache__` / `.pytest_cache` appear in listings (not ignored).
**Why it matters.** These read as sloppiness, not honest work-in-progress — the one
impression this project can least afford.
**Done when.** `corpus/_bak;C` is gone; exactly one guard hook exists and it is the
wired one; `.gitignore` covers `__pycache__/`, `.pytest_cache/`, and any other
build/test cruft; `git status` is clean of them.

### A.6 — Reconcile the number/count drifts
**Problem.** Small inconsistencies a hostile reviewer uses to argue "if the small
numbers don't reconcile, why trust the big ones":
- `docs/adr/0002` targets "~80–160 golden records"; actual corpus is 67 (below the
  band). ADR-0007 supersedes at 67 but 0002 was never reconciled/annotated.
- `corpus/capture-golden.sh` comments say "the 11 tranche-1 procedures" while the
  `PROCS` array lists 14.
- `demo/README.md:24` says "The eight steps" then lists ten (0–9).
- `GetStockHoldingUpdates` has only 1 golden case vs 4–6 for its siblings — a thin
  branch-coverage spot for a zero-param proc (fix or note why 1 is sufficient).
**Done when.** Each number agrees with the corpus as built, or carries an explicit
"superseded by ADR-0007 (67)" annotation; `demo/README.md` count matches its list;
`GetStockHoldingUpdates` coverage is either raised or justified in a comment.

---

## Tier B — Substance *(days; moves 7.5→9, "design doc"→"demonstrated result")*

This is where the load-bearing claims get *shown* rather than *asserted*. B.3 is
the single highest-leverage item in the whole tracker.

| # | Task | Target file(s) | Status |
|---|------|----------------|--------|
| B.1 | De-hardcode the gates over the corpus | `gates/differential.sh`, `gates/mutation-check.sh`, `gates/build.sh`, `gates/verify.sh`, `generated/runners.json` | done |
| B.2 | Convert 2–3 more procs, incl. one decimal-bearing | `generated/GetStockHoldingUpdatesService.cs` (+ csproj/runner/test) | done |
| B.3 | Minimal real eval harness + one honest result | `evals/harness.py`, `run.sh`, `.github/workflows/eval-live.yml`, `evals/results/run-001.json` | blocked (operator dispatch) |
| B.4 | Naive single-prompt baseline (the control) | `evals/results/baseline.json` | blocked (operator dispatch) |
| B.5 | Wire the gates into CI as required checks | `.github/workflows/verify.yml` | done |
| B.6 | Gate-time seed-identity assertion | `gates/differential.sh` (or `verify.sh`) | done |

**B.1 done.** The gates are proc-agnostic, driven by a new manifest
`generated/runners.json` (proc → csproj/assembly/service) plus a **uniform runner
contract**: every runner takes the case's `params` as one JSON value on argv, so
`differential.sh <Proc>` passes `corpus/cases/<Proc>.json`'s params through verbatim
with zero per-proc knowledge, and reads `--ordered` from the case's `ordered` flag.
`build.sh`/`verify.sh` loop the whole manifest; `mutation-check.sh` takes a `<Proc>`
and applies that proc's own catalogue. Adding a converted proc is a manifest entry +
its files under `generated/` — no gate edit. (Windows gotcha closed: the `py`
launcher emits CRLF, so every manifest/case value captured in the scripts is piped
through `tr -d '\r'`, or a trailing CR breaks path/`.dll` lookups.)

**B.2 done.** `Integration.GetStockHoldingUpdates` (zero-param, decimal-bearing) is
converted end-to-end and green: differential 1/1, unit 8/8 across both procs. The
**precision mutant now fires and is caught** on a real run — closing the gap
`mutation-check.sh` used to only *disclose*. Verified the catch is genuine (the
mutant emits well-formed JSON; it is caught because reading `LastCostPrice` through a
double collapses `8.00`'s fixed scale to bare `8`, ≠ golden `"8.0000"`), not a crash.
Branch-hole note recorded in the mutation script: the `8.00` row is load-bearing —
the `12.50` row alone would not catch the mutant.

### B.1 — De-hardcode the gates over the corpus
**Problem.** `gates/differential.sh` and `mutation-check.sh` hardcode
`PROC="Website.SearchForCustomers"` and its argv contract (`SearchText`,
`MaximumRowsToReturn`). There is no generic differential — "the gate" reproduces
exactly one proc's verdict. This is the dominant scale wall.
**Why it matters.** Without parameterisation, the corpus-wide framing has no
foundation, and every new proc needs a copy-pasted runner. (MLOps, hiring)
**Done when.** Proc name, param mapping, and shape/`--ordered` decision are driven
from `corpus/cases/<Proc>.json` (already the source of truth for cases); running
`differential.sh <Proc>` works for any converted proc with no script edit.
**Depends on:** unblocks B.2 (each new proc gets gated for free).

### B.2 — Convert 2–3 more procs, including one decimal-bearing
**Problem.** The flagship claim is decimal precision (`decimal(18,4)→Decimal128`,
called "the precision thesis of the whole artifact" in `decimal-mapping/SKILL.md`).
The one converted proc returns **no decimal column**, so the precision mutant
(ADR-0006) is never actually run. `mutation-check.sh:18-24` honestly concedes this
— but "I disclosed it" is not "I closed it".
**Why it matters.** Until a `decimal(18,4)→float` mutant is *caught by an executed
run*, the marquee guarantee is asserted, not shown; and "it's really just one proc"
stays true.
**Done when.** At least one money-returning `Integration.Get*Updates` proc is
converted end-to-end and green on its differential, AND the precision mutant fires
and is caught against it. Bonus: one temporal proc, to exercise that tier too.
**Depends on:** B.1 (so the new procs are gated without hand-editing scripts).

**B.3 harness built, blocked on a live run.** `evals/harness.py` + `evals/run.sh`
exist and are complete: they drive the four-stage pipeline through the real
`claude -p` headless CLI, enforce the retry cap of 2 across attempts (the Stop hook
is now proc-aware via `CONVERT_PROC`), decompose the gate into a failure taxonomy
(`failed:build|unit|differential|retry_cap`), and compute the pre-registered
`cleared_within_cap` metric — including the **SHA-256 identity check** the
pre-registration promises (canonical produced output vs canonical golden), plus a
`source_sha256` so a reviewer can confirm which artifact was measured. A model-free
`--dry-run` exercises every deterministic part against the committed services and
is **green (2/2, both hashes identical)** — this is the scaffold proof, gitignored
and explicitly not citable as a result. **What is missing is the one thing that
needs a model: the live `run-001.json`.**

**The live-path blocker was diagnosed and closed (2026-08-10).** An in-session
attempt to drive the headless agent produced a *false* "2/3 cleared" result — every
proc at zero tokens, zero cost, null snapshot — which was quarantined (deleted), not
committed: it was a dry-run wearing a live label, the exact composed result the
pre-registration forbids. Root cause: a `claude -p` spawned **from inside a Claude
Code session** never authenticates, because `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`
strips the model-access secret (`ANTHROPIC_FOUNDRY_API_KEY` — the CLI here reaches
the model through Anthropic Foundry, `CLAUDE_CODE_USE_FOUNDRY=1`) from every
subprocess Claude Code launches. With the key gone the CLI falls back to a token
provider that has nothing and returns `api_error` at zero tokens — which is why the
"live" run silently degraded to a dry-run wearing a live label. *(An earlier note
here mis-diagnosed this as an Azure-AD / service-principal problem and the fix
carried Azure boilerplate; that was wrong — the auth is Foundry-key, not Azure — and
has been corrected in `.env.example` and the workflow.)* The model string
`claude-opus-4-8-gateway` was always correct: it is exactly what `~/.claude/
settings.json` uses.

**Two honest ways to produce the real result, neither of which is "from inside a
Claude Code session":**
- **Locally**, from a plain shell (not the agent's subprocess) that has
  `ANTHROPIC_FOUNDRY_API_KEY` + `ANTHROPIC_FOUNDRY_RESOURCE` in its environment:
  `EVAL_LIVE_OK=1 bash evals/run.sh --live`. The harness inherits the shell's env,
  so each `claude -p` it spawns authenticates.
- **In CI**, via the manual-only `.github/workflows/eval-live.yml`: it pulls the
  Foundry key + resource from Infisical, probes headless auth before spending a cent,
  drives the real agent through the gate, and uploads `run-001.json` as an artifact
  for a human to review and commit — the honest way to get the number, produced by a
  logged, authenticated job rather than typed.

**B.3/B.4 are now blocked only on the operator** running one of the two above —
nothing left to build. The tail of B.3 (revert A.3 to present tense, replace the
demo's illustrative Phase-4 table, fill `PREREGISTRATION.md:15` with the captured
snapshot) stays parked until that artifact exists. B.4 (baseline) rides the same
plumbing.

**B.6 done.** `gates/differential.sh` now, right after `seed-mongo.sh` regenerates
`relational.json`, diffs the fresh export against the committed copy the golden was
captured from and fails loudly on any drift (ADR-0001/0003) — closing the one live
non-circularity risk (a container whose SQL Server exports subtly differently would
drift Mongo from golden silently). It runs exactly once per `verify.sh` (the seed
step it hangs off is `NO_SEED=1`-skipped for the rest of the loop). Compared
line-ending-normalised, not byte-for-byte: the `py` launcher writes CRLF on Windows,
so it is *content* identity we assert (verified the assertion has teeth — an injected
byte is caught — and that a clean export passes).

**B.5 done.** `.github/workflows/verify.yml` runs on every push/PR to `main`: it
brings the two engines up via the SAME `docker-compose.yml` a reviewer uses (not
GitHub `services:` — the seed path shells in with `docker compose exec mssql`, so
the containers must be compose-managed), waits on both healthchecks, then runs
`gates/verify.sh` + `gates/mutation-check.sh` + the harness `--dry-run`, all with
`PYTHON=python3` and no model. The seed is self-contained (`relational.sql` drops
and recreates the DB from fixed literals — no 121 MB `.bak` restore needed in CI).
Two portability fixes this needed: the unit tests hardcoded the Windows `py`
launcher for their `canonicalise.py` shell-out — now they resolve `$PYTHON` → `py`
→ `python3`; and the README status block, stale at "one showcase proc / 5-5 / 5-5",
was reconciled to the 2-proc / 6-6 / 8-8 reality alongside the new badge on line 1.
*(Making it a strictly **required** check is a one-time branch-protection setting in
the repo UI, which a workflow cannot set for itself.)*

### B.3 — Minimal real eval harness + one honest result  ⭐ highest ROI
**Problem.** The third pillar of the thesis — "measurement that proves it did" —
is vaporware. No `harness.py`, no `run.sh`, no `results/`. The retry cap of 2 "lives
in the harness" that doesn't exist, so a real run today is an unbounded loop
(`stop-differential.sh` blocks a red finish forever, by its own admission — no
memory). Every headline number (accuracy, $/proc, flaky rate) is a promise.
**Why it matters.** This is the difference between 7.5 and 9. It does not need all
14 procs or a polished harness — a thin harness that runs the real agent headless
over 3 procs and emits ONE result file with real accuracy + cost + one honest
failure converts the whole project from "impressive design" to "demonstrated". (all
three, ranked #1 by hiring + MLOps)
**Done when.** `evals/harness.py` + `run.sh` exist and: pin model + sampling params
(fill `PREREGISTRATION.md:15`), enforce the cap of 2, compute the
`cleared_within_cap` SHA-256 identity check `PREREGISTRATION.md:27` promises, and
write `evals/results/run-001.json` with per-proc verdict + retries + tokens + $ for
≥3 procs including one that honestly fails. Then A.3's tense reverts to present, and
the demo's Phase-4 "(illustrative)" table is replaced with the real one.

### B.4 — Naive single-prompt baseline (the control)
**Problem.** H2 in `PREREGISTRATION.md` claims the staged pipeline beats a naive
single prompt. With no baseline, that claim is currently unfalsified — the fatal
interview question ("how do you know staged beats a prompt? n=1, by hand, no
control").
**Why it matters.** The baseline is what makes the whole "agentic engineering > a
prompt" argument an experiment instead of an assertion.
**Done when.** `evals/results/baseline.json` runs the same procs through a single
unstaged prompt under the same gate, so run-001 has something to be *better than*.
**Depends on:** B.3 (same harness plumbing).

### B.5 — Wire the gates into CI as required checks
**Problem.** The only workflow is `pages.yml` (uploads `demo/` to Pages). No CI runs
`verify.sh` or `mutation-check.sh`. For a project whose whole pitch is "a
deterministic gate reproduces the verdict", the gate being absent from CI is the
largest credibility gap after the missing harness — the central claim is never
exercised by automation. (MLOps ranked this #1; hiring/pre-sales concur)
**Why it matters.** A green badge GitHub vouches for is worth more than any prose,
and it is the industry-standard order (gate-in-CI first, demo second) this repo
currently inverts.
**Done when.** `.github/workflows/verify.yml` brings up SQL Server + Mongo service
containers on .NET 10 and runs `gates/verify.sh` + `gates/mutation-check.sh` as
required status checks on push/PR to `main`; a green badge lands on README line 1
(this is Phase-5 task 5.2, promoted here). Free — no model calls.

### B.6 — Gate-time seed-identity assertion
**Problem.** `differential.sh` reseeds Mongo every run via `seed-mongo.sh`, which
re-applies `relational.sql` to SQL Server and re-exports `relational.json`. But the
*golden* was captured in an earlier run. Nothing re-verifies that the freshly
exported `relational.json` still matches the committed one the golden derived from.
If the container's SQL Server produces even a subtly different export (collation,
geography WKT, float→decimal edge), the Mongo side silently drifts from golden and
no assertion catches it. `verify-stable.sh` checks golden↔golden, not
golden-seed↔mongo-seed at gate time.
**Why it matters.** It is the one live drift risk in an otherwise airtight
non-circularity story — closing it makes the strongest claim in the repo actually
airtight instead of trusting-the-regeneration. (MLOps)
**Done when.** After `seed-mongo.sh` regenerates `relational.json`, the gate diffs
it against the committed copy and fails loudly on drift.

---

## Tier C — Sellable-as-a-capability *(before pitching "I can deploy this")*

The reviews are unanimous that deployability to a client environment is currently
near-zero, and that this is fine *if positioned honestly* — but fatal if oversold.

| # | Task | Target file(s) | Status |
|---|------|----------------|--------|
| C.1 | State the method's applicability ceiling up front | `README.md` | done |
| C.2 | Client-deployability story (on-prem, PII, onboarding cost) | `docs/DEPLOYABILITY.md` (new), `docs/SECURITY.md` | done |
| C.3 | Positioning: sell the thinking, not a finished product | `README.md` (pitch), demo lede | done |

**Tier C closed.** Exit notes:

**C.1 done.** A fourth bullet in README's "What this is *not*" names the ceiling
in that section's own voice: the oracle covers read-only / deterministic /
single-result-set procs (verbatim the `corpus/SELECTION.md` criteria), it is a
hard structural limit not an effort one (a state-mutating proc has no stable output
to capture; a non-deterministic one produces a different "golden" each run), and the
stateful/non-deterministic majority of a real backlog needs a *different* harness
(snapshot-and-compare, transaction-rollback). No claim implies corpus-wide
generality. Mirrored in `README.uk.md`.

**C.2 done.** New `docs/DEPLOYABILITY.md` answers the four buyer questions head-on:
(a) the Claude Code dependency — the *gate* is model-agnostic and runs offline for
$0, the *generator* needs Claude Code API access and has no air-gapped story today;
(b) the PII gap — the demo only sidesteps it by using public sample data, and a
masking/synthesis step (derive shape + branch-covering cases from the real schema,
synthesise the rows, capture golden over synthetic input so non-circularity holds)
is a stated prerequisite, not built; (c) secrets — the `.env`-in-argv smell named
with the secrets-manager / least-privilege-principal fix; (d) per-proc cost — the
*shape* stated honestly (gate integration near-zero and free; generation cost is the
number the harness is built to measure, deliberately unstated until `run-001.json`).
`docs/SECURITY.md` carries the concrete secret handling, the PII/synthesis
prerequisite, supply-chain pinning, and the threat-model boundary (the model is
deliberately outside the trusted base for correctness). Both linked from
`docs/README.md`. Both mirrored in `.uk.md`.

**C.3 done.** The demo lede no longer opens "An AI wrote this migration" (an implied
autonomy the harness doesn't demonstrate) — it now leads with the engineering
discipline and states outright that a human carried the showcase through the stages
by hand. README claim #3 and the "reviewer will find here" harness paragraph are
softened from present-tense autonomy to "built to / next step," with the by-hand
fact stated explicitly. Mirrored in `README.uk.md`. Nothing now claims autonomy the
harness doesn't yet show; the pitch is the judgment (non-circular oracle, proven
teeth, pre-registration), not a finished product.

### C.1 — State the method's applicability ceiling up front
**Problem.** The oracle technique structurally applies only to **read-only,
deterministic, single-result-set** procs — `corpus/SELECTION.md` excludes
`GETDATE`/`NEWID`/`SYSDATETIME` and base-table writers. In a real 500-proc backlog
the majority write state, use non-deterministic functions, return multiple result
sets, or depend on session state. This is a hard ceiling, not a matter of effort.
It is implied in `SELECTION.md` but a reviewer evaluating scale needs it up front.
**Why it matters.** Named openly, it turns a perceived hole into a scoped,
defensible claim ("I address the tractable tier correctly, here's what the rest
needs"). Buried, it reads as the method silently failing on 80% of the work.
**Done when.** One README paragraph: this method covers read-only/deterministic/
single-result-set procs; stateful/non-deterministic procs (the majority of a real
backlog) require a different harness (snapshot-and-compare against captured DB
state, transaction-rollback). No claim implies corpus-wide generality.

### C.2 — Client-deployability story
**Problem.** `ADR-0004` openly admits generation "ties the artifact to Claude Code;
reproduction needs it" — with no on-prem/air-gapped/no-external-API answer. Worse,
the method requires exporting real production tables to `relational.json`
(committed to git) to feed `to_mongo.py` — i.e. **customer data in the repo, with
no masking/synthesis step**. That is a blocker for exactly the enterprises that
have 500-proc T-SQL backlogs. Secrets today are `.env` with `MSSQL_SA_PASSWORD`
interpolated into argv — fine for a demo, a red flag in a client security review.
**Why it matters.** "I'll deploy this at your place" is an overreach until these are
answered; a sharp technical buyer asks all three in the first meeting.
**Done when.** A short `docs/DEPLOYABILITY.md` answers: (a) Claude Code dependency
and the on-prem/air-gapped story (or honest "requires Claude Code access"); (b) a
PII masking/synthesis step so real tables never land in a repo; (c) secrets via a
manager, not `.env` in argv; (d) a realistic per-proc onboarding cost. `docs/SECURITY.md`
(Phase-5 task 5.4) covers the supply-chain + secret handling.

### C.3 — Positioning: sell the thinking, not a finished product
**Problem.** The demo lede "An AI wrote this migration" (`demo/index.html:~312`) is
aspirational — the one conversion was carried through the four stages **by hand**
(`:~350`), not by an autonomous headless run, and that autonomous path is exactly
what doesn't exist yet.
**Why it matters.** Sold as a finished product ("deploy in your env"), it gets
caught. Sold as proof of engineering *judgment* (non-circular oracle, proven teeth,
pre-registration against metric-fishing), it is a genuine senior signal that can't
be faked by prompting. Lead with the discipline; de-emphasise the numbers and the
"AI does the work" framing until B.3 lands.
**Done when.** The pitch (README opening + demo lede) frames the artifact as "how I
*design* a trustworthy AI migration", the manual-orchestration fact is not implied
away, and nothing claims autonomy the harness doesn't yet demonstrate.

---

## Cross-cutting notes (not tasks, but keep in view)

- **The mutation catalogue is co-tuned with the seed.** ADR-0006 says an uncaught
  mutant means "comparison too loose OR seed branch-hole", and the fix is to add a
  seed row until the catalogue is caught. Author-tunes-both is a reasonable loop but
  does not generalise to *unknown* wrong conversions — only to the five named
  classes. Worth a sentence in METHOD.md so it isn't read as full correctness.
- **`AsString(...).TrimEnd()` in the service (`SearchForCustomersService.cs:~155`)**
  duplicates canonicaliser logic — the code pre-conforms its output to the
  comparator. Minor, but it's the same "shaped to the gate" coupling the project
  polices on the data side. Consider removing the service-side trim and letting the
  canonicaliser own normalisation.

## How this file dies

Same as [`README.md`](README.md): when a tier is fully `done`, its findings are
either fixed in the artifact (the diff is the record) or captured as a permanent
note in the doc they corrected (ADR / architecture / METHOD / DEPLOYABILITY), and
the tier's table is deleted. When every tier is `done`, delete this file in the
same commit that retires the build tracker.
