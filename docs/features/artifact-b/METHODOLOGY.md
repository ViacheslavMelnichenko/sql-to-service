---
feature: artifact-b
slug: artifact-b
updated_at: 2026-08-07
status: draft
owner: Viacheslav Melnichenko
companions: [IMPLEMENTATION-PLAN.md, SUCCESS-CRITERIA.md]
---

# Artifact B — Measurement Methodology

`IMPLEMENTATION-PLAN.md` says **how we build**. `SUCCESS-CRITERIA.md` says **what
"done" means**. This document says **how the numbers are produced so a skeptic
believes them** — the part that separates an *eval* from a *demo with a table*.

For an "AI Platform Engineer" artifact the methodology is not supporting material;
it **is** the product. Anyone can print a pass rate. The signal is proving the
pass rate is reproducible, not noise, not cherry-picked, and earned by the
pipeline rather than by an easy corpus. Every section below is a decision that
biases the result if made silently, so each is made in writing, before the run.

A short version of this document becomes `evals/METHOD.md` (referenced from the
README). This file is the full rationale; `METHOD.md` is the operational extract.

---

## 0. Scope under the S / 4-evening budget

Not everything here is affordable. Marked honestly so the bar isn't gold-plated:

- **CORE** — without it the published numbers are meaningless. Ships in the base
  build. (§1 pinning, §2 k-runs, §5 cost model, §6.1 false-positive gate check,
  §8 pre-registration.)
- **STRETCH** — high signal, added if evenings allow; each is cheap because it
  reuses the harness. (§3 baseline, §4 ablation, §7 retry-cap curve.) If cut,
  they are cut **loudly** in METHOD.md ("not measured"), never silently.

The rule from the plan holds: a silent cap reads as "covered everything". Any
STRETCH item not done is named as not-done.

---

## 1. Reproducibility protocol (CORE)

A number nobody can reproduce is a screenshot. Everything that affects the result
is pinned and recorded **in each run's record**, not in prose that drifts:

| Pinned input | How | Recorded in |
| --- | --- | --- |
| Model | exact API id **and** snapshot date (e.g. `claude-sonnet-4-5-YYYYMMDD`) — not a floating alias | `run-NNN.json` header |
| Sampling | `temperature`, `top_p`, `max_tokens` — fixed and logged | run header |
| Corpus | `select.sql` output hash + `procs/*.sql` git SHA | run header |
| Seed | `relational.sql` + `to_mongo.py` git SHA | run header |
| Golden | `golden/*.json` content hash | run header |
| Pipeline | stage specs + standards git SHA | run header |
| Pricing | the price-per-token table + its date (§5) | run header |
| Toolchain | .NET SDK, Mongo driver, container image digests | run header |

The run header makes a run a **fingerprinted experiment**. Two runs are
comparable only if their headers differ in exactly the dimension under test
(e.g. only the pipeline SHA changed between run-001 and run-002).

---

## 2. The stochasticity problem — k-runs, not one (CORE)

The model is non-deterministic even at `temperature=0` (batching, routing). A
single corpus pass yields one sample of a random variable, so:

- **Each configuration is run k times** (default **k=3**; k=5 if a result is
  close to a decision boundary). The corpus is small, so k passes are affordable.
- **Report the distribution, not a point.** Table 1 gains a spread column:
  pass rate as `median (min–max over k)`, cost as `median [p10–p90]`.
- **Per-procedure convertibility is a stability class**, not a boolean:
  - `stable-pass` — cleared in all k runs.
  - `flaky` — cleared in some, failed in others. **This is a first-class result**,
    not an embarrassment: it says the conversion is on the edge of the model's
    reliability, which is exactly the kind of thing a platform team must know.
  - `stable-fail` — failed in all k runs.
- A cost/pass **delta between two configs counts only if it exceeds the
  within-config spread.** run-001→run-002 improvement is claimed only if
  `median(run-002) < min(run-001)` (non-overlapping), otherwise it is reported as
  "within noise" — which is itself an honest, publishable finding.

This single discipline is what makes the trajectory claim falsifiable instead of
anecdotal.

---

## 3. Baseline / control (STRETCH, high value)

Differential testing proves a conversion is correct. It does **not** prove the
*pipeline* earned its complexity. The control answers "did the staged pipeline
beat just asking the model once?":

- **Naive baseline:** one prompt — "convert this procedure to a .NET + Mongo
  service" — no analyse/review stages, run through the **same three gates** and
  the **same k-runs**.
- The headline becomes a **comparison**: pipeline `X/N` vs naive `Y/N`, with the
  same corpus and gates. If `X ≈ Y`, the pipeline is over-engineered and we say
  so; if `X ≫ Y`, that delta is the artifact's central evidence.
- Cost is compared too: the pipeline is more expensive per attempt but may clear
  more procedures per dollar. Report cost-per-**cleared**-proc, not per-attempt —
  the honest denominator.

Without a baseline, "83 %" (or whatever the demo gets) floats with no reference;
with one, it has a control group.

---

## 4. Ablation (STRETCH — proves governance-as-code isn't decoration)

The résumé claims standards/ADRs encoded into the pipeline change outcomes. That
is testable, not assertable:

- **Drop the review stage** (the one that enforces the machine-checkable
  standards) and re-run k times. If pass rate and standards-conformance are
  unchanged, the governance layer is decoration — publish that. If they drop, the
  delta is the measured value of governance-as-code.
- **Standards-conformance is measured separately from correctness:** a conversion
  can be differentially-correct yet violate a standard (wrong decimal type,
  blocking IO). Count both. Correct-but-non-conformant is a distinct outcome and a
  real one.

One ablation (review on/off) is enough for S. More stages ablated = M-sized work.

---

## 5. Cost model (CORE)

"$0.31/proc" is meaningless without stating how the 0.31 was computed:

- **Formula, published:** `cost = Σ(input_tokens × price_in + output_tokens ×
  price_out + cache_read_tokens × price_cache_read)` across every stage and every
  retry of the procedure, using the pricing table pinned in the run header (§1).
- **Cache reads are priced at their own rate**, not the input rate — this is where
  most of the spend hides and where the optimization pass (caching the stable
  prefix) shows up. Reporting them merged into input tokens would hide the exact
  lever the trajectory claim rests on.
- **Cache-state confound is controlled:** prompt caching makes the *second* run of
  anything cheaper regardless of optimization. So run-001 and run-002 are each
  measured from a **cold cache**, or the cache contribution is reported separately
  so the reader sees optimization vs warm-cache. This is stated in METHOD.md; a
  cost reduction that is really just cache warmth is the exact dishonest number
  this section exists to prevent.
- **Cost-per-cleared-proc** is the headline denominator (§3), because cost per
  attempt rewards giving up early.

---

## 6. Gate validation — validating the gate itself (CORE + STRETCH)

The gate certifies the conversions; nothing certifies the gate unless we do it.

### 6.1 False-positive check (CORE)

A differential gate that fails a *correct* conversion because of a normalization
quirk (decimal scale, row order, NULL encoding) silently deflates the pass rate.
So: the one hand-verified procedure (B2-5) is run through the gate and **must
pass** — and its known-good output is perturbed only in *format* (reorder keys,
change decimal scale, reorder tied rows) to confirm the canonicaliser absorbs
format differences and the gate still passes. If format noise fails the gate, the
canonicaliser is wrong, not the conversion.

### 6.2 False-negative check (CORE — this is AC-2)

A gate that never fails is not a gate. A deliberately wrong output (off-by-one in
a decimal, a dropped row, a flipped NULL) **must** fail the gate with a row-level
diff. Present in the plan as AC-2; it is the gate's teeth.

### 6.3 Seed branch coverage (STRETCH but strongly recommended)

Golden output is only a valid oracle if the seed **exercises the procedure's
logic**. A seed that hits only the happy path makes both golden and generated
agree trivially — a false pass that no differential can catch, because both sides
are blind to the same branch. So coverage is measured, not assumed:

- For each proc, enumerate its branches (WHERE predicates, CASE arms, JOIN
  match/no-match, NULLable columns) and record which seed rows exercise each.
- Publish per-proc coverage. An unexercised branch is a **known limitation stated
  in METHOD.md**, not a hidden one. This is the honest answer to "how do you know
  the golden output isn't just the easy case?"

### 6.4 Human spot-check (CORE, cheap)

Even with §6.1–6.3, a small blind spot survives: golden and generated both wrong
because the seed missed a branch. Mitigation: a fixed, pre-declared **sample of 3
cleared procedures is read by hand** and the reading is logged. Not a gate — a
calibration check that the automated verdict matches human judgment on a sample.
If it ever disagrees, that is the most important finding in the repo.

---

## 7. Statistical honesty & sensitivity (mixed)

- **Small-n is stated, not hidden (CORE).** With 12–20 procedures a pass rate has
  a wide confidence interval. METHOD.md states n and gives the rough interval
  (e.g. 11/16 is 69 % but the 95 % CI spans roughly 41–89 %). Pretending n=16
  yields a precise percentage is the exact overconfidence a senior reviewer
  punishes. The taxonomy (which failed and why) carries more weight than the
  percentage at this n, and the document says so.
- **Retry-cap sensitivity curve (STRETCH).** Report pass rate at cap = 0, 1, 2.
  The shape shows how much of the result is first-try quality vs retry recovery —
  and re-proves that the published cap (2) is a real ceiling, not tuned upward
  until the number looked good.

---

## 8. Pre-registration (CORE, nearly free)

Extends the plan's "criterion before outcome" from corpus selection to the whole
eval. **Before run-001**, commit a `evals/PREREGISTRATION.md` stating:

- The exact metric definitions (already in METHOD.md).
- k, the retry cap, the model id, the corpus (by hash).
- The comparison hypotheses ("run-002 median cost < run-001 min"; "pipeline
  cleared > naive cleared").
- What would count as a **negative** result and that it will be published anyway.

Committed and git-timestamped before the run, this makes it impossible to
retrofit the thresholds to the outcome. It is the single cheapest credibility
move in the whole artifact.

---

## 9. Flow completeness — three things the pipeline flow still needs

Measurement aside, the *flow* has gaps that affect the numbers:

### 9.1 Retry feedback loop
When a gate fails and `run.py` retries, the agent **must receive the gate's
failure** (the compiler error, the failing assertion, the row-level differential
diff) as input to the next attempt — otherwise a retry is just a re-roll and the
cap-2 pass rate is meaningless. The methodology measures **retry lift**: how many
procedures clear on attempt 2 *because* they saw the diff. If retries with
feedback don't beat blind re-rolls, feedback isn't working.

### 9.2 Escalation output
The procedures that hit the retry cap (`SUCCESS-CRITERIA.md` §2.2 `failed:*`) must
produce a **structured escalation report** — proc name, last failing gate,
row-level diff, the attempts — not just a red mark. This is the demo of "the
remaining 17 % escalate to review": escalation is a deliverable a human could act
on, and its shape is part of the artifact.

### 9.3 Run trace / observability
Every stage, gate, retry and cost event is written to a structured, replayable
**run log** (`evals/results/run-NNN.trace.jsonl`), so a run is auditable after the
fact without re-running it. This is the SDLC DoD's "observability" item for the
pipeline, and it is what lets §6.4's human spot-check inspect a decision.

---

## 10. What each measurement defends (traceability)

So no measurement is ceremony:

| Measurement | Defends against | Backs |
| --- | --- | --- |
| Model+pricing pinning (§1) | "unreproducible screenshot" | falsifiability (SC §3.2) |
| k-runs + spread (§2) | "that's just noise / one lucky run" | trajectory (SC §2.6) |
| Baseline (§3) | "did the pipeline do anything?" | 2-pipeline claim |
| Ablation (§4) | "governance is decoration" | ADRs/standards claim |
| Cost model + cache control (§5) | "cheaper is just warm cache" | cost-reduction claim |
| Gate validation (§6) | "the gate is too loose / too strict" | non-circular gate |
| Small-n honesty (§7) | "n=16 can't yield a precise %" | credibility (SC §2.5) |
| Pre-registration (§8) | "thresholds fit to the result" | no-cherry-pick |
| Retry feedback (§9.1) | "cap-2 pass rate is meaningless" | halt+retry claim |

---

## 11. Introduced specifics (overrule cheaply)

Choices this document adds beyond the plan:

- **k=3 default k-runs** with the non-overlapping-spread rule for claiming a delta
  — the specific bar for "the improvement is real, not noise".
- **`flaky` as a first-class per-proc outcome class** alongside stable-pass/fail.
- **Naive single-prompt baseline** and a **review-stage ablation** as the two
  control conditions (STRETCH).
- **Cost-per-cleared-proc** (not per-attempt) as the headline cost denominator.
- **Cold-cache measurement** (or separated cache accounting) between run-001/002.
- **`evals/PREREGISTRATION.md`** committed before run-001.
- **`run-NNN.trace.jsonl`** structured run trace + a **3-proc human spot-check**.
- **Seed branch-coverage** published per proc as the golden-output validity check.
