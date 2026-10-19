# Design — Integrating the AST into the conversion pipeline (brainstorm outcome)

**Date:** 2026-10-19
**Status:** approved (direction chosen; Phase 2 evidence-gated, not yet active)
**Owner:** Viacheslav Melnichenko
**Supersedes scope of:** [2026-10-18-ast-grounding-design.md](2026-10-18-ast-grounding-design.md) §7 (pipeline wiring), which this makes precise and turnkey.

> **Укр. резюме:** Зібрали командою агентів, які взагалі є правильні способи вбудувати
> AST (feature cards) у наш пайплайн конверсії, і кожен звірили з головним інваріантом
> некруговості (ADR-0001). Головне переусвідомлення: некруговість — це про те, що
> **модель не може вплинути на власного суддю**, а НЕ «факти з того самого SQL».
> Тому годувати AST **генератору** (analyst/implementer) — безпечно (golden усе одно
> судить незалежно); годувати **судді** (golden/differential/verify/Stop-hook) —
> заборонено. Обраний напрям — **A: картка як «крок 0» для analyst**, але строго за
> дисципліною ADR-0008: вмикати лише після **виміряного промаху**.

---

## 1. The reframe that orders everything

Non-circularity (ADR-0001) is about the **model being unable to influence its own
judge** — it is **not** the blanket rule "anything derived from the same SQL is tainted."
The golden *is itself* an output of that same SQL (the original proc run on a seed).
Locate the JUDGE precisely and every integration verdict falls out. The judge is:

- the **golden**, captured from the original T-SQL before any model runs;
- `gates/differential.sh` / `gates/verify.sh`, which compare to it value-by-value;
- `.claude/hooks/stop-differential.sh`, the **Stop hook** that runs the differential
  in-loop and blocks an early finish (the in-loop enforcer of the verdict).

From that:

- Anything that flows **only into the generator** (analyst, implementer, or the advisory
  reviewer agent) is **SAFE** for non-circularity, no matter how much SQL it parses — the
  golden independently catches errors.
- Anything that **shapes an input to the golden** (the seed) or **emits an artifact adjacent
  to the judge** is **CONDITIONAL** — non-circular by construction, but only while a
  `features-check.sh`-style standalone grep-proof keeps it out of the verdict path.
- **UNSAFE** is the one move none of the patterns require but each can decay into: letting a
  SQL-derived artifact **define "correct"** (feed the golden/differential, be the sole
  completeness oracle, or gate a PASS on a lint). That is ADR-0008's rejected Option 2.

## 2. The option space (team-of-agents brainstorm)

| # | Pattern | Plugs in | Circularity | Effort |
|---|---------|----------|-------------|--------|
| **A** | Feature card as **analyst step-0 grounding** | generator input, before the spec | **SAFE** | low |
| **F** | **Strengthen the observability lens** (chip→golden-column xref, coverage audit) | human reviewer only | **SAFE** | medium |
| **D** | AST **routes skills/prompts** (feature-based retrieval) | orchestrator/harness, not agents | conditional | low |
| **C** | AST drives **seed/test generation** (branch coverage) | before golden capture | conditional | medium |
| **B** | AST → **deterministic scaffold**, model fills meaning | pre-stage, writes generated/ | conditional | medium |
| **E** | AST as **advisory structural lint** (warn, never decide) | standalone, exit 0 always | conditional | medium |

Guardrail common to every conditional pattern: the same discipline ADR-0006/0008 already
model — a **standalone, grep-proven powerlessness** check, plus honest degradation on the
`parse_status: degraded` temporal procs (cursors / `SYSTEM_TIME`).

## 3. Chosen direction: A — analyst step-0 grounding, evidence-gated

The user's original idea ("AST as prepared input / step 0"). It is the cheapest and cleanest,
and it does **not** break non-circularity. It is **not adopted on faith** (ADR-0008): it turns
on only after a **measured miss**. Two gated phases.

### Phase 1 — Produce (don't engineer) a measured miss  *(prerequisite; user's shell)*

The trigger (ADR-0008 Deferral): the harness shows the analyst **repeatedly** misreading a
semantic the card detects — e.g. a `LEFT JOIN` whose unmatched rows must survive, silently
converted as INNER / `$lookup`+`$unwind` without `preserveNullAndEmptyArrays` →
`failed:differential` on row survival; or a `decimal`→`Decimal128` precision loss.

- **Where it must run:** a PowerShell window the user opens — **not** from inside a Claude
  Code session. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` strips the Foundry API key from
  subprocesses Claude Code spawns, so a headless `claude -p` launched from within a session
  cannot authenticate (see `evals/run-live.ps1` header).
- **How:** finish the pre-registered **k=3** campaign and the **B.4 baseline**, and extend the
  hunt to the harder/under-seeded procs (the 11 not yet converted), where a misread is more
  likely than on the tractable three:
  ```powershell
  # the pre-registered samples
  powershell -ExecutionPolicy Bypass -File evals\run-live.ps1    # -> next run-001.sample-0N.json
  # a targeted miss-hunt over harder procs (override the run set)
  $env:EVAL_LIVE_OK = "1"
  py evals\harness.py --run-id miss-hunt --procs Integration.GetMovementUpdates Website.SearchForStockItemsByTags
  ```
- **Honest outcome:** the miss may simply **not** reproduce on this corpus. The eval is 3/3
  clean today. "A stays deferred" is then the correct, recorded result — the artifact's whole
  thesis is refusing to adopt on faith. No miss → no wiring. This is a feature, not a stall.

### Phase 2 — Wire the grounding  *(only if Phase 1 fires; turnkey below)*

1. **`.claude/agents/analyst.md`** — add a bounded *"Grounding input (lowest authority)"*
   section: read `corpus/features/<Proc>.features.json`; honour `parse_status` (a `degraded`
   card is not trusted blindly); the **golden stays the tiebreak**. Fixed precedence:
   **golden > skills > features**.
2. **`gates/features-check.sh` check 5** — re-scope `LOOP_FILES` to the **judge set only**:
   `verify.sh`, `differential.sh`, `stop-differential.sh`, `post-write-build.sh` (+ the
   golden-capture script) — and **drop `.claude/agents/*.md`** from the forbidden set. Net:
   the mechanical proof becomes "no **judge** file reads a card" (today it is "no agent either"),
   which deliberately permits the generator read while keeping the verdict firewalled. (The
   Stop/PostToolUse hooks were added to this set on 2026-10-19 independently of wiring — a pure
   strengthening that closed a real gap.)
3. **A/B evidence** — re-run the miss proc **with** grounding; show the same miss now clears.
   Honest caveat: a pass still means "matches golden" (real), but the *gain* is attributable to
   grounding only via the with/without A/B, not asserted.
4. **Docs** — move ADR-0008 Option 1 from *Deferred* to *Accepted-under-measured-miss*, record
   the trigger; update `architecture.md` §3 (the feature-extract box moves onto the analyst's
   input) and §5b.

### Invariant held throughout
`corpus/golden/*`, `gates/differential.sh`, `gates/verify.sh`, `corpus/seed/to_mongo.py` are
**untouched**. The judge causally predates the card and reads zero bytes from it.

## 4. Done in this pass (no measured miss required)

- **Defect fix:** `features-check.sh` check 5 now also forbids the in-loop verdict enforcers
  (`stop-differential.sh`, `post-write-build.sh`) from reading a card — the Stop hook that
  enforces the differential was previously unguarded.
- **Framing fix:** the demo (EN + UK) and `architecture.md` §5b previously implied that feeding
  the *converter* a card would be circular. It would not — only feeding the *judge* is. Corrected
  to the §1 reframe.
- **ADR-0008 sync:** the proven-powerless file list now names the Stop hook.

## 5. Not done (and why)
- **Grounding is not wired.** No measured miss exists (3/3 clean, 0 retries). Wiring now would
  violate ADR-0008. Correctly deferred.
- **The live miss-hunt was not run from here.** It requires the user's own shell (auth scrub).
  The exact commands are in §3 Phase 1.
