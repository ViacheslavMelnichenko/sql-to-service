# Eval results

Committed result files from `evals/harness.py`. Each is a JSON record whose schema
is described in `harness.py`'s header and whose success criteria are pre-registered
in [`../PREREGISTRATION.md`](../PREREGISTRATION.md) — **written before any run and
never edited to match a number**.

| File | What it is | Status |
|------|------------|--------|
| `run-001.sample-0N.json` | One independent live sample: the staged pipeline driven by the real agent over the run set, retry cap 2. k=3 of these make a distribution. | sample 01 measured (`claude-opus-4-8`, 3/3 cleared); 02–03 pending. Produce with `bash evals/run.sh --live` / `evals/run-live.ps1`. |
| `run-001.json` | The **aggregate** of the samples: per proc, `cleared/k`, `flaky`, and the cost/token spread. The primary result. | built by `py evals/aggregate.py` from the samples above; currently a k=1 **partial** distribution. Recomputable, never hand-written. |
| `summary.md` | The analysis paragraph — what the run showed read against the pre-registration. The one artifact that can't be faked. | present, scoped to the samples that exist. |
| `baseline.json` | The naive single-prompt control (B.4), same procs, same gate. What `run-001` has to beat (H2). | not yet run |
| `dry-run.json` | Scaffold check: the harness run with **no model**, measuring the already-committed services. Proves the plumbing (gates, SHA-256 identity, JSON emission) end to end. | **gitignored** — not a citable result. Reproduce with `bash evals/run.sh`. |

## Reading a result honestly

- **`mode`** tells you everything. `"dry-run"` means no model touched it: `model`,
  `cost_usd`, and `tokens` are null/0 by construction, and it must never be cited
  as `run-001`. `"live"` is a real, paid, model-driven run.
- **`cleared_within_cap`** is the pre-registered primary metric: the proc passed
  build + unit + differential within the retry cap **and** the canonical output the
  built service produces is SHA-256 identical to the canonical golden. The two
  hashes are in `identity` so anyone can recompute them. In a **sample** file it is
  a boolean per proc; in the **aggregate** it becomes `cleared/k` per proc.
- **`source_sha256`** records *which* service file was measured, so a reviewer can
  hash the committed file and confirm the eval ran the artifact in the repo — not a
  hand-fixed copy.
- **`independent`** (aggregate only) is the audit that a sample really regenerated:
  a proc that recorded 0 agent turns did not, and is flagged so a stale artifact
  can't pad the distribution.
- Across the k samples a proc is **expected** to be allowed an honest non-`cleared`
  outcome (`failed:differential`, `failed:retry_cap`, or `flaky`); a clean sweep is
  a finding to investigate, not a success (PREREGISTRATION.md, H3). That
  investigation is written in [`summary.md`](summary.md), not waved away.

## How `run-001.json` is produced

Never by hand. Each live sample is gated behind an explicit opt-in (`run.sh --live`
sets `EVAL_LIVE_OK` only after a typed confirmation) because it spends real API
budget and drives a headless agent loop with tool access. Three samples, then
`py evals/aggregate.py` stitches them into `run-001.json` — a *computed* file, never
a composed one. The samples are committed alongside it, so the aggregate is
recomputable from its inputs and a reviewer never has to trust the summary over the
data.
