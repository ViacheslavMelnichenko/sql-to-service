# Pre-registration

Written **before `run-001`**, committed, and never edited to match a result. Its
purpose is to make the eval falsifiable: the hypotheses and thresholds are fixed in
git *before* the numbers exist, so a reviewer can check we didn't retrofit the
success criteria to whatever the pipeline happened to produce. If a result
contradicts a prediction here, the prediction stays and the contradiction is
reported — that is the point of writing it down first.

> **Status:** registered, pre-run. No results exist yet. Any figure below is a
> *prediction*, explicitly marked as such.

## Fixed before the run

- **Model + version:** `<model-id, dated>` — pinned in `evals/METHOD.md`, frozen
  before run-001.
- **Sampling:** temperature and top-p fixed and recorded; same for every run.
- **Corpus:** the procedures selected by `corpus/SELECTION.md`, frozen before the
  run — no procedure added or removed after seeing a result.
- **Retry cap:** 2 (a conversion gets at most two gate-feedback retries).
- **k:** 3 runs per configuration, to report a distribution rather than a point.

## Metric definitions (fixed)

- **`cleared_within_cap`** — the primary metric. A procedure counts as cleared iff
  it passed build + unit + differential within the retry cap, **and** the committed
  output is byte-identical (SHA-256) to what the run produced. Mechanically
  checkable; not a judgment.
- **Per-proc outcome** is exactly one of: `cleared` · `failed:build` ·
  `failed:unit` · `failed:differential` · `failed:retry_cap` · `flaky` (differs
  across the k runs).

## Hypotheses (predictions, to be confirmed or refuted)

- **H1 — the gate catches wrongness.** The mandatory mutation check (ADR-0006)
  catches **100%** of the injected mutation catalogue before run-001 is trusted.
  *This is a gate on the gate; if it fails, no result is reported until it passes.*
- **H2 — staged beats naive.** The staged pipeline clears **more** procedures than
  the single-prompt baseline. Direction predicted; magnitude not.
- **H3 — not everything clears, and that's expected.** Some procedures will land in
  `failed:differential` or `flaky`. A 100% clear rate would be treated as a
  **finding to investigate** (seed too weak? comparison too loose?), not a success.
- **H4 — cost is bounded and reported.** Per-proc cost is recorded under a
  **cold-cache** control (see METHOD), so a cheaper later run can't be mistaken for
  a real improvement when it's just cache warmth.

## What would falsify the thesis

Stated up front so it can't be explained away later:

- The mutation check cannot be made to catch all injected bugs even after closing
  seed holes → the gate is not trustworthy; the central claim fails.
- The baseline clears as many procedures as the staged pipeline → the staging adds
  no value; the "engineering, not a prompt" claim weakens.
- Results are irreproducible run-to-run beyond the declared `flaky` set → the
  measurement isn't honest and must be fixed before publishing.

## Analysis committed in advance

- Report the **distribution** across k=3, not a single number.
- Publish the **failure taxonomy** (Table 2) with an analysis paragraph — including
  when failures are few.
- Report a **confidence interval** appropriate to small n; do not present a point
  estimate as precise.
- Keep the **demo-vs-reality firewall**: these magnitudes are the demo's own and
  stand in for no real engagement.

## Introduced specifics (overrule cheaply)

- **k=3** and **retry cap 2** are chosen for the S budget — enough to see variance,
  cheap enough to run repeatedly.
- **H2/H3 predict direction, not magnitude** deliberately — pre-registering a
  number we then "hit" would be theater.
