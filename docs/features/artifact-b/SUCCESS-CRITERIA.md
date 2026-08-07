---
feature: artifact-b
slug: artifact-b
updated_at: 2026-08-07
status: draft
owner: Viacheslav Melnichenko
companion: IMPLEMENTATION-PLAN.md
---

# Artifact B — Success Criteria & Measurement

Companion to `IMPLEMENTATION-PLAN.md`. That document says **how we build**; this
one says **what "done well" means and how we prove it with numbers**. It defines
three separate things people conflate:

1. **Deliverables** — the concrete files/state that must exist.
2. **Conversion success** — did the pipeline convert each procedure *correctly*,
   and how do we measure that mechanically.
3. **Artifact success** — did the repository do its job for the person who reads
   it (a hiring reviewer), and how do we know.

Every threshold below is a **target set before the run**, not a result. Real
numbers land in `evals/results/` after run-001/run-002. Where the demo cannot
hit an engagement-scale number, that is expected and governed by the
demo-vs-engagement firewall (`IMPLEMENTATION-PLAN.md` §0.1) — we report what the
demo actually did, honestly, and never borrow the résumé's figures.

---

## 1. Deliverables — what must exist at the end

Binary presence checks. Each is either there or not; no judgement.

| # | Deliverable | Exists-when |
| --- | --- | --- |
| D1 | Reproducible corpus | `corpus/restore.sh` + `select.sql` + `SELECTION.md` (criterion, full candidate list, exclusions) committed; a clone reproduces the proc set |
| D2 | Golden output | `corpus/golden/*.json`, one per selected proc, canonical, stable across a cold rebuild |
| D3 | Dual-store seed | `corpus/seed/relational.sql` + `corpus/seed/to_mongo.py`; Mongo seed is a pure function of the relational seed (AC-9) |
| D4 | Pipeline | `pipeline/run.py` + 4 stage specs + 4–6 machine-checkable standards; gates between stages; halt-on-first-failure; retry cap 2 |
| D5 | Gates | `gates/{build,unit,differential}.sh`; differential uses the shared value-based canonicaliser |
| D6 | Committed generated output | `generated/*` reviewers can read without paying |
| D7 | Eval harness + records | `evals/harness.py`; `results/run-001.json` and `run-002.json`; one full record per proc per run |
| D8 | Two published tables | `results/summary.md` Table 1 (headline) + Table 2 (failure taxonomy) with the analysis paragraph |
| D9 | Governance | 6 ADRs, all `Accepted`; `docs/SECURITY.md`; CHANGELOG; KB note |
| D10 | CI | `verify.yml` (free, no model calls, green) + `regenerate.yml` (`workflow_dispatch`) |
| D11 | Drift mode | `--drift` regenerates only a changed source proc |

DoD in `IMPLEMENTATION-PLAN.md` §11 is the sign-off gate over these.

---

## 2. Conversion success — did the pipeline convert correctly

This is the technical heart: **for one procedure, what does "converted
correctly" mean, and how is it measured without trusting the model.**

### 2.1 The unit of measurement

Per procedure, per run, the harness records one JSON object (schema in
`IMPLEMENTATION-PLAN.md` §8). The decisive field is:

> **`cleared_within_cap`** = passed build **and** unit **and** differential gates
> within ≤2 retries, **and** the committed `generated/` output is byte-identical
> (SHA-256) to what `run.py` produced. Any later edit flips it false.

The differential gate is the one that means something: generated .NET (reading
the mechanically-seeded Mongo) is run, its result set normalised by the *same*
`canonicalise.py` as the golden file, and compared **by value**. Mismatch = hard
fail. The model never certifies its own output.

### 2.2 Per-procedure outcome states

Every procedure lands in exactly one bucket. These are mutually exclusive and
cover the whole corpus (no proc is dropped):

| Outcome | Meaning |
| --- | --- |
| `cleared` | `cleared_within_cap = true` |
| `failed:build` | never compiled within the cap |
| `failed:unit` | agent tests failed within the cap |
| `failed:differential` | compiled, tests passed, output differs from golden |
| `failed:retry_cap` | still failing after 2 retries, escalated |

`failed:differential` is the most informative: it means the conversion *looked*
right and was *semantically* wrong — exactly the failure human review misses, and
exactly what the differential gate exists to catch.

### 2.3 Corpus-level conversion metrics (Table 1 — headline)

Computed by the harness, published verbatim on the README first screen.

| Metric | Definition | Target for the demo to be worth publishing |
| --- | --- | --- |
| Procedures in corpus | count of selected procs | 12–20 (hard cap 20) |
| Cleared unedited | `cleared` count and % | **report actual** — a credible demo, not a suspicious one; see §2.5 |
| Median cost / proc | median `cost_usd` | report actual (cents-scale expected) |
| p90 cost / proc | 90th pct `cost_usd` | report actual |
| Median attempts to clear | median total attempts of `cleared` procs | report actual (≈1–2 expected) |
| Median wall clock | median `wall_clock_s` | report actual |

### 2.4 Failure taxonomy (Table 2 — the credibility multiplier)

| First failing gate | Count | Typical cause (filled from real runs) |
| --- | --- | --- |
| build | — | e.g. referenced a helper the analyse stage invented |
| unit | — | e.g. generated test asserted its own wrong behaviour |
| differential | — | e.g. NULL / collation / decimal-scale semantics |
| retry_cap | — | — |

Plus the 2–3 sentence paragraph on what the `differential` failures had in
common. **This paragraph is the single measurement that cannot be faked without
doing the work** — its presence and specificity is itself a success criterion.

### 2.5 What counts as a *credible* conversion result (not just a high one)

A demo that reports 100 % is less credible, not more — it reads as a cherry-picked
corpus or a circular gate. Success here is **an honest number with a taxonomy**,
not a maximised number. Concretely, the demo's conversion result is a success iff:

- The pass rate is reported alongside the retry cap and the full candidate list
  (so nobody can suspect hidden retries or a dropped-hard-proc corpus).
- At least one `differential` failure exists and is analysed — proving the gate
  has teeth (AC-2) and that hard procedures were kept, not excluded.
- The number is reproducible: re-running the committed `generated/` through
  `verify.sh` reproduces the same cleared/failed split with no model calls.

If every proc cleared trivially, that is a **finding to investigate** (corpus too
easy, gate too weak), not a win.

### 2.6 The trajectory (backs the résumé's "down from ~$60" *shape*, not the value)

Two runs, published together:

| | run-001 | run-002 | Δ |
| --- | --- | --- | --- |
| Median cost / proc | $a | $b | `(a−b)/a` |
| Cleared unedited | x % | y % | — |
| What changed | — | trim stage inputs, cache stable prefix, tighten prompts | — |

Success = a **real, method-explained cost reduction with no pass-rate
regression**. A before/after with a method note is self-authenticating; the
*absolute* dollars are demo-scale and explicitly not the engagement's $25.

---

## 3. Artifact success — did the repo do its job

The pipeline can convert perfectly and the artifact can still fail its actual
purpose: making a skeptical senior reviewer trust the profile in 90 seconds.
These criteria measure that.

### 3.1 The 90-second test (the primary artifact metric)

A reviewer opens the repo and reads the first README screen. Success iff, without
scrolling past it, they can answer:

1. **Real work or tutorial?** → the results table + kept-every-proc criterion +
   committed generated output answer "real".
2. **Did they measure anything?** → Table 1 + Table 2 + cost delta answer "yes".
3. **What do they consider important?** → non-circular gate + published cap +
   "what this is not" answer "correctness and honesty".

Measurement (proxy, since we can't instrument the reviewer): a fresh reader — a
peer asked to spend 90 seconds — can restate all three answers from the first
screen alone. If they can't, the first screen has failed and is rewritten.

### 3.2 The falsifiability test

Success = **a stranger can clone and disprove us if we're lying.**

- `docker compose up -d && ./corpus/restore.sh && ./gates/verify.sh` passes on a
  clean machine, with no API key, making no model calls.
- The published `generated/` output actually clears the gates it claims to.
- Every number in the README traces to a committed record in `evals/results/`.

An unfalsifiable artifact (a demo video, uncheckable numbers) scores zero here
regardless of how good it looks.

### 3.3 The confidentiality test

Success = **a competitor cannot reconstruct the client or the engagement.** No
client/product/DB/person names; no engagement volumes or dollar figures; nothing
but public WWI. Measured by a pre-publish leak scan (grep for known engagement
terms, reviewer read-through). A single leak fails this outright — it is a gate,
not a score.

### 3.4 The overclaiming test

Success = **the demo never claims the engagement's magnitudes as its own.** The
§0.1 firewall paragraph is present in README and METHOD; the demo's headline maps
to the demo's corpus; the résumé's 83 %/$25 are attributed to the engagement. A
reviewer reading both documents finds them consistent, not contradictory.

---

## 4. Scorecard (fill after run-002)

One place, so success is legible at a glance. `✓ / ✗ / n` per row.

| Dimension | Criterion | Status |
| --- | --- | --- |
| Deliverables | D1–D11 all present (§1) | — |
| Conversion | pass rate reported with cap + candidate list (§2.5) | — |
| Conversion | ≥1 differential failure analysed (§2.4) | — |
| Conversion | verify.sh reproduces the split, no model calls (§2.5) | — |
| Conversion | run-001→run-002 cost Δ with no pass regression (§2.6) | — |
| Artifact | fresh reader passes the 90-second test (§3.1) | — |
| Artifact | clean-machine clone reproduces results (§3.2) | — |
| Artifact | leak scan clean (§3.3) | — |
| Artifact | firewall present, no overclaim (§3.4) | — |
| Governance | 6 ADRs Accepted, SECURITY.md, CHANGELOG, KB note (§1 D9) | — |

**Overall success** = every Deliverable present **and** every Artifact-dimension
row ✓. Conversion rows are reported honestly rather than forced to a threshold —
a low-but-analysed pass rate with teeth beats a high-but-unexplained one.

---

## 5. Explicit non-goals for measurement

So the bar is not moved after the fact:

- We do **not** target a specific pass-rate percentage; we target an honest,
  reproducible, analysed one.
- We do **not** measure the demo against the engagement's $25/proc or 83 %; those
  are out-of-scope magnitudes (§0.1 firewall).
- We do **not** count lines of generated code as a success signal; `generated_loc`
  is recorded for context, not scored.
- We do **not** treat "all procs cleared" as the best outcome (§2.5).
