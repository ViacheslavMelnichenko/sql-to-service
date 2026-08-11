# run-001 — analysis

The one artifact in this repo that cannot be produced without having done the work:
what the run actually showed, read honestly against what the pre-registration
predicted. Numbers come from the committed sample files
(`run-001.sample-0N.json`) and their aggregate (`run-001.json`); anyone can
recompute the aggregate with `py evals/aggregate.py`.

> **Status: k=1 of the pre-registered k=3.** One live sample has been measured
> (`run-001.sample-01.json`, model snapshot `claude-opus-4-8`, temperature 0,
> retry cap 2). The pre-registration (`PREREGISTRATION.md`) fixes **k=3 runs per
> configuration** so a distribution can be reported instead of a point; two more
> live samples are pending. Every claim below is scoped to the sample(s) that
> exist, and the section is written to be updated in place — not rewritten — as
> samples 2 and 3 land.

## What the sample showed

| Proc | Outcome | Retries | Cost (USD) | Turns |
|------|---------|--------:|-----------:|------:|
| `Website.SearchForCustomers` | cleared | 0 | 3.68 | 30 |
| `Integration.GetStockHoldingUpdates` | cleared | 0 | 2.84 | 24 |
| `Integration.GetTransactionUpdates` | cleared | 0 | 4.39 | 44 |
| **total** | **3/3 cleared** | 0 | **10.91** | 98 |

All three cleared on the first attempt, no retries, and each built service's
canonical output is SHA-256 identical to the golden captured before any model ran
(the hashes are in the sample file; the model-free dry run reproduces them exactly,
which is what makes the pass auditable rather than asserted).

## The finding: a clean sweep is not a headline (H3)

The pre-registration predicted this outcome would *not* happen, on purpose:

> **H3 — not everything clears, and that's expected.** … A 100% clear rate would be
> treated as a **finding to investigate** (seed too weak? comparison too loose?),
> not a success.

So 3/3 is not reported as a win here — it is the trigger for the investigation H3
demands. Three candidate explanations, and where each lands:

1. **The comparison is too loose.** *Rejected on the evidence available.* The same
   differential and canonicaliser are shown to have teeth by the mandatory mutation
   check (ADR-0006): injected bugs — including the `decimal(18,4)→double` precision
   mutant against `GetStockHoldingUpdates` — are caught, so the gate is not passing
   everything indiscriminately. A loose comparator would fail the mutation check
   first, and it does not.

2. **The seed is too weak** to make a wrong conversion visibly wrong. *Partially
   open, and the honest caveat.* Each proc's branch coverage is only as good as its
   cases: `GetTransactionUpdates` exercises four (both date arms, the COALESCE
   fallback, and an empty window), `SearchForCustomers` five, but
   `GetStockHoldingUpdates` rests on a **single** zero-parameter case. A defect that
   only shows on a branch the seed never exercises would clear this gate. This is
   the live limitation of the result, not something the clean sweep disproves.

3. **The task is genuinely tractable for these three procs.** *The most likely
   reading.* All three are read-only, deterministic, single-result-set procedures —
   exactly the tier `corpus/SELECTION.md` scopes the oracle method to, and exactly
   where a strong model plus a staged pipeline plus an in-loop gate *should* land a
   correct conversion. The applicability ceiling (README "What this is not") is the
   point: on the tractable tier, clearing is the expected result — which is why the
   honest signal is not the pass rate but the **cost** and the **failure taxonomy**,
   and why the baseline (B.4) matters more than another green run.

**What would move this from "plausibly tractable" to "measured":** the two
remaining k=3 samples (does any proc turn out `flaky` run-to-run at temperature 0?),
and the naive single-prompt baseline (B.4) — if the baseline clears all three too,
the staging is unproven for this set and H2 weakens; if it does not, the staged
pipeline earned its complexity here.

## Cost

Per-proc cost this sample: $2.84–$4.39, mean $3.64, total $10.91 for the three.
This is a **cold-cache** sample (H4) — the first paid run of these procs — so a
cheaper later sample would be cache warmth, not a real improvement, and is reported
as such. Cost is the number the harness was built to measure and the one that does
not saturate at 100%, so it, not the clear rate, is the honest headline once k=3
completes.

## Reproducing

```sh
bash evals/run.sh                 # model-free: reproduces the identity hashes at $0
py evals/aggregate.py             # rebuild run-001.json from the committed samples
```

The per-sample files, the aggregate, and this analysis move together; if a number
here disagrees with `run-001.json`, the JSON is authoritative and this file is
stale.
