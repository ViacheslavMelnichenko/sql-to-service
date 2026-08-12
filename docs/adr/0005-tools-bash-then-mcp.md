# 0005 — Gate-tools: Bash scripts now, MCP as a stretch

- **Status:** Accepted
- **Date:** 2026-08-07
- **Deciders:** Viacheslav Melnichenko

## Context

The deterministic judgments — capture golden, build, run unit tests, run the
differential — are the tools the agents call. There are two natural ways to expose
them to a Claude Code agent: as CLI scripts invoked through the Bash tool, or as
typed tools served by a custom MCP server. This is a size-vs-signal trade-off for a
size-S artifact.

## Decision drivers

- Keep the size-S budget; don't add a subsystem the artifact doesn't need to prove
  its thesis.
- The gate must be inspectable by a human *and* callable by a hook *and*
  callable by the agent — ideally the same artifact for all three.
- Leave a clear, honest path to demonstrate MCP competence without inflating scope
  now.

## Considered options

1. **MCP server from the start.** Typed contract (`run_procedure`,
   `diff_against_golden`), a stronger signal. Rejected for now — a whole server to
   build and maintain, and it inflates the artifact past S before the core thesis
   is even standing.
2. **Bash scripts only, forever.** Simple and honest, but leaves the MCP
   competence unshown.
3. **Bash now, MCP as a labelled stretch.** Chosen.

## Decision

Expose the gate-tools as **Bash scripts** under `gates/` (`build.sh`, `unit.sh`,
`differential.sh`, `verify.sh`, `mutation-check.sh`). One script is:

- **callable by the agent** through the Bash tool,
- **callable by a hook** (`PostToolUse`, `Stop`) with the same invocation,
- **readable by a human** as plain shell — the gate has no hidden magic.

**MCP is a planned stretch, not part of the core.** Once the harness and gate are
standing and the budget allows, one tool (`diff_against_golden`) is reimplemented
as a small MCP server as a demonstration of the typed-contract approach — clearly
marked as optional and additive, never blocking the core.

## Consequences

- **Positive:** fewer moving parts; the gate is the same shell artifact for agent,
  hook, and human. `verify.sh` reproduces the published table with no model calls.
- **Positive:** honest MCP path exists without paying for it up front.
- **Cost:** a Bash script is a weaker "typed contract" signal than MCP — accepted;
  the stretch closes it if the budget remains.
- **Cost:** shell portability care (CI and the local run both use Linux containers;
  scripts target POSIX sh).

## Links

- ADR-0004 — the Claude Code substrate these tools plug into
- `gates/*.sh` — the tool scripts
- `docs/tasks/README.md` — MCP tracked as a stretch, not a Phase gate
