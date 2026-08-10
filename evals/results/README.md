# Eval results

Committed result files from `evals/harness.py`. Each is a JSON record whose schema
is described in `harness.py`'s header and whose success criteria are pre-registered
in [`../PREREGISTRATION.md`](../PREREGISTRATION.md) — **written before any run and
never edited to match a number**.

| File | What it is | Status |
|------|------------|--------|
| `run-001.json` | The staged pipeline, driven by the real agent over the run set, retry cap 2. The primary result. | **not yet run** — needs a live headless run (`bash ../run.sh --live`) in an environment that permits an agent loop with tool access. |
| `baseline.json` | The naive single-prompt control (B.4), same procs, same gate. What `run-001` has to beat (H2). | not yet run |
| `dry-run.json` | Scaffold check: the harness run with **no model**, measuring the already-committed services. Proves the plumbing (gates, SHA-256 identity, JSON emission) end to end. | **gitignored** — not a citable result. Reproduce with `bash ../run.sh`. |

## Reading a result honestly

- **`mode`** tells you everything. `"dry-run"` means no model touched it: `model`,
  `cost_usd`, and `tokens` are null/0 by construction, and it must never be cited
  as `run-001`. `"live"` is a real, paid, model-driven run.
- **`cleared_within_cap`** is the pre-registered primary metric: the proc passed
  build + unit + differential within the retry cap **and** the canonical output the
  built service produces is SHA-256 identical to the canonical golden. The two
  hashes are in `identity` so anyone can recompute them.
- **`source_sha256`** records *which* service file was measured, so a reviewer can
  hash the committed file and confirm the eval ran the artifact in the repo — not a
  hand-fixed copy.
- A live run is **expected** to contain at least one honest non-`cleared` outcome
  (`failed:differential`, `failed:retry_cap`, or `flaky`); a clean sweep is a
  finding to investigate, not a success (PREREGISTRATION.md, H3).

## Why `run-001.json` isn't here yet

The harness is complete and its scaffold is proven green by the dry run. The live
run is deliberately gated behind an explicit opt-in (`run.sh --live` sets
`EVAL_LIVE_OK` only after a typed confirmation) because it spends real API budget
and drives a headless agent loop with tool access. Producing `run-001.json` is a
single authorised command once that environment is available — and it will be a
*measured* file, never a composed one.
