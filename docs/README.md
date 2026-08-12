# Documentation index

Every document in this repository, in reading order. Start at the top; each
layer assumes the one above it.

The design is deliberately split across small files rather than one large
document — one decision per ADR, so a single claim can be checked without reading
the whole argument, and so a decision can be revised without touching the others.
This page is the map that ties them together.

## Start here

| Document | What it answers |
| --- | --- |
| [`../README.md`](../README.md) | *What* this is: the thesis, the end-to-end flow, how to reproduce. The front door. |
| [`architecture.md`](architecture.md) | *Why it is shaped this way.* Expands the README's three diagrams into the reasoning. Permanent — outlives the task tracker. |
| [`../demo/`](../demo/) | A guided, step-by-step walkthrough of the repo (open `demo/index.html`, or see [`demo/README.md`](../demo/README.md)). Each step pairs a command with the output that proves it worked. |

## Decision records (ADRs)

Each ADR is one frozen decision the pipeline depends on. They are permanent.

| ADR | Decision |
| --- | --- |
| [0001](adr/0001-non-circular-gate.md) | **Non-circular gate** — the oracle is captured from the original T-SQL *before any model runs*, so the AI cannot collude with its judge. The load-bearing idea. |
| [0002](adr/0002-dataset-sizing.md) | **Dataset sizing** — the corpus is sized for *branch coverage*, not volume; the seed must discriminate the behaviours the gate compares. |
| [0003](adr/0003-mechanical-mongo-seed.md) | **Mechanical Mongo seed** — the MongoDB seed is a pure function of the relational seed, so the comparison isn't quietly hand-fitted. |
| [0004](adr/0004-claude-code-substrate.md) | **Claude Code as substrate** — the four primitives (subagents, skills, hooks, tools) *are* the engineering, not a wrapper. |
| [0005](adr/0005-tools-bash-then-mcp.md) | **Gate tools: Bash first, MCP later** — gates are POSIX-sh under `gates/`; an MCP server is a labelled stretch. |
| [0006](adr/0006-mutation-validation.md) | **Mutation validation** — inject known bugs and require the gate to catch every one; a gate never shown to fail is untested. |
| [0007](adr/0007-purpose-built-seed-two-tranches.md) | **Purpose-built seed, two tranches** — how the seed is grown to cover the procs without becoming a fixture for the answer. |

## The pipeline

| Document | What it covers |
| --- | --- |
| [`../pipeline/retry.md`](../pipeline/retry.md) | The loop's error path: how a gate failure is fed back to the agent (in-loop hooks) and where the retry cap lives (the harness, Phase 4). |

## Measurement (Phase 4 — k=1 of k=3 in)

The harness is built and has produced its first live sample; the pre-registered
distribution completes at k=3. The result records below are real, and scoped to
that k=1 wherever they are cited.

| Document | What it covers |
| --- | --- |
| [`../evals/PREREGISTRATION.md`](../evals/PREREGISTRATION.md) | The measurement method, registered *before* the numbers exist, so the results are falsifiable. The harness (`evals/harness.py`) and its result records are written against this spec. |
| [`../evals/RUNNING.md`](../evals/RUNNING.md) | The operational runbook: how to run the harness (dry vs live, POSIX vs Windows), the prerequisites, the authentication traps, and how to diagnose a failing live run. |
| [`../evals/results/README.md`](../evals/results/README.md) | How to read a result file honestly — what `mode`, `cleared_within_cap`, and the SHA identity mean. |
| [`../evals/results/run-001.json`](../evals/results/run-001.json) + [`summary.md`](../evals/results/summary.md) | The first live run: three procs converted end to end by the real agent, each cleared against the frozen golden ($2.84–$4.39/proc). Aggregated from `run-001.sample-01.json` by `evals/aggregate.py`; k=1 of the pre-registered k=3, and the 3/3 clean sweep is treated as a finding to investigate (H3), not a headline. |

## Build scaffolding (temporary)

| Document | What it covers |
| --- | --- |
| [`tasks/README.md`](tasks/README.md) | The phase-by-phase task tracker that drives the build. **Temporary by design** — each row is deleted once its target file exists and is gated; permanent design docs (ADRs, architecture) are moved into `docs/` rather than deleted. Forward-looking file names in the Phase-4 rows (e.g. `evals/harness.py`, `evals/results/*`) name what *will* exist, and are marked `todo`. |

## Corpus provenance

| Document | What it covers |
| --- | --- |
| [`../corpus/SOURCE.md`](../corpus/SOURCE.md) | Where the corpus comes from and how it is pinned (URL + SHA). |
| [`../corpus/SELECTION.md`](../corpus/SELECTION.md) | Which procedures were selected, the criterion, and what was excluded. |

## Deploying it for real

The honest answer to *"could you run this at a client?"* — what ports, what needs a
model, and what must be built before real data is touched.

| Document | What it answers |
| --- | --- |
| [`DEPLOYABILITY.md`](DEPLOYABILITY.md) | The Claude Code dependency and on-prem story, the PII/data-in-repo gap and the masking step that closes it, secrets handling, and the shape of the per-proc onboarding cost. What is a portable capability vs. an overreach. |
| [`SECURITY.md`](SECURITY.md) | Concrete secret handling, PII/synthesis prerequisite, supply-chain pinning, and the threat-model boundary — why the model is deliberately outside the trusted base for correctness. |
