# 0004 — Claude Code as the substrate: real agents, skills, hooks, tools

- **Status:** Accepted
- **Date:** 2026-08-07
- **Deciders:** Viacheslav Melnichenko

## Context

The thesis is "engineering *around* AI," so the agentic machinery has to be real,
not a slogan. A thin Python script that calls a model API in a loop and names its
functions "agent" and "hook" would be exactly the thing this artifact exists to be
better than. The reviewer we're aiming at knows the difference on sight.

## Decision drivers

- The four primitives (subagents, skills, hooks, tools) must be *actual platform
  mechanisms*, so the labels are backed by reality, not renamed code.
- Context separation between stages must be structural, not simulated by trimming
  a prompt string.
- The target reviewer should recognize their own tools when they open the repo.

## Considered options

1. **Framework-agnostic thin orchestrator.** A hand-rolled loop with our own
   "agent"/"hook" abstractions. Rejected — the primitives would be ours to define
   loosely, and a senior would open it and find the labels unbacked. Higher risk of
   reading as "a script pretending to be an agent."
2. **A general agent framework (LangGraph / similar).** Rejected for this artifact
   — adds a dependency whose primitives don't map as cleanly, and it's not the
   platform the audience is evaluating.
3. **Build on Claude Code — subagents, skills, hooks, tools are native.** Chosen.

## Decision

The pipeline is built **on Claude Code**, using its native primitives:

- **Subagents** (`.claude/agents/*.md`) — one per stage (`analyst`, `implementer`,
  `test-author`, `reviewer`), each with its own system prompt, model, and tool-set.
  Context separation is built into the platform, not imitated.
- **Skills** (`.claude/skills/*`) — conversion standards as versioned files the
  `reviewer` loads and checks against.
- **Hooks** (`.claude/settings.json`) — `PostToolUse`, `Stop`, `PreToolUse` gate
  transitions automatically, in-loop.
- **Tools** — deterministic gate-scripts the agents call (see ADR-0005).

**Honesty constraint:** the agent/stage/tool distinction must be *real in the
code*. If `analyst` and `implementer` are genuinely different system prompts with
different tool-sets and separated context, they are honestly "agents." If a
distinction turns out to be cosmetic, we rename it to what it is (a "stage") rather
than let an unbacked label cost more later.

## Consequences

- **Positive:** the primitives are backed by platform mechanism; `.claude/` becomes
  a first-class exhibit a reviewer recognizes.
- **Positive:** hooks give us in-loop gating for free — the "gate every transition"
  claim is a platform feature, not our plumbing.
- **Cost:** ties the artifact to Claude Code; reproduction needs it. Acceptable —
  the audience is evaluating exactly this substrate.
- **Cost:** running the real agent headless per procedure (for the harness) is
  non-trivial, but it's what makes the measured numbers honest (ADR is the
  harness's problem; see METHOD).

## Links

- ADR-0005 — how tools are exposed (Bash now, MCP later)
- `.claude/agents/`, `.claude/skills/`, `.claude/settings.json`
- `README.md` — the four-primitive diagram
