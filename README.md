# sql-to-service

[![verify](https://github.com/viacheslavmelnichenko/sql-to-service/actions/workflows/verify.yml/badge.svg)](https://github.com/viacheslavmelnichenko/sql-to-service/actions/workflows/verify.yml)

**An engineering harness that makes an unreliable AI trustworthy on a real
migration task.**

> 🖥️ **[Live walkthrough → viacheslavmelnichenko.github.io/sql-to-service](https://viacheslavmelnichenko.github.io/sql-to-service/)** —
> a guided, step-by-step tour of the whole harness. Each step pairs a command
> with the output that proves it worked.

The task — converting legacy T-SQL stored procedures into a .NET + MongoDB
service layer — is the *vehicle*, not the point. Anyone can ask a language model
to translate code. The interesting problem is the one every team hits the moment
they try to *ship* what the model wrote: **the model is confidently wrong often
enough that you cannot trust its output without an independent way to catch it.**

This repository is that independent way. It is built **on Claude Code**, using its
native primitives — subagents, skills, hooks, and tools — so the "AI engineering"
here is real platform mechanism, not a wrapper script pretending to be an agent.

> **Status:** design-complete, implementation in progress. Two kinds of number
> live in this project, and the difference is the whole point:
> - The **gate results** exist today and are reproducible at $0 with no model call
>   — two converted procs passing their differential (6/6 cases, incl. a
>   decimal-bearing proc), the mutation check catching 8/8 injected bugs across both
>   (incl. the `decimal→double` precision mutant), the oracle stable across 67 golden
>   files. Run `gates/verify.sh` + `gates/mutation-check.sh` and you regenerate them
>   yourself; the [walkthrough](https://viacheslavmelnichenko.github.io/sql-to-service/)
>   shows each one paired with its command.
> - The **eval numbers** — corpus-wide accuracy, per-proc cost, the failure
>   taxonomy — do **not** exist yet. They land with the Phase-4 harness
>   (`evals/harness.py`), and where one would go this document says so plainly
>   rather than showing a placeholder.

---

## What this proves

Not "AI can convert SQL." It can. This proves something a reviewer actually cares
about:

> *I don't ask a model to convert code — I build the system that lets you **trust**
> an unreliable model on migration work: an independent oracle that catches its
> mistakes, and measurement that proves it did.*

Three things carry that claim:

1. **A non-circular gate.** The correctness oracle is captured from the *original*
   procedure **before any model runs**, so the AI cannot collude with the thing
   that judges it.
2. **Agentic engineering, not a prompt.** Staged subagents with separated context,
   governed by skills, gated by hooks — the way a production agent is actually
   built.
3. **Honest measurement.** A harness runs the real agent headless over every
   procedure and reports accuracy *and* cost, including the failures — because a
   result with no failures is a finding to investigate, not a win.

---

## The flow, end to end

```mermaid
flowchart LR
    subgraph before["① Before any AI"]
        proc[Original T-SQL<br/>procedure]
        golden[(Golden output<br/>captured from<br/>the original)]
        proc -- "run on seeded data" --> golden
    end

    subgraph ai["② AI does the work — staged Claude Code subagents"]
        analyst[analyst<br/><i>read-only</i>]
        impl[implementer]
        tests[test-author]
        review[reviewer]
        analyst --> impl --> tests --> review
    end

    subgraph gate["③ The gate judges — deterministic tools"]
        build{build}
        unit{unit tests}
        diff{differential<br/>vs golden}
        build --> unit --> diff
    end

    subgraph measure["④ The harness measures"]
        report[accuracy + cost<br/>+ failure taxonomy]
    end

    golden -.->|independent oracle| diff
    proc --> analyst
    review --> build
    diff -->|per-proc verdict + cost| report
```

Read it as one sentence:

> **Golden captured before the AI → subagents do the work in stages → hooks gate
> every transition through deterministic tools → the harness measures honestly.**

The gate is the load-bearing idea. The agent's *own* generated tests never pass
the gate on their own — they could be wrong in the same direction as the code.
Only the **differential** — the generated service's output compared value-by-value,
after canonicalisation, against the golden output captured before the model existed
— has the authority to say "this conversion is correct." (Canonicalisation means
decimals are rendered at a fixed scale and object keys sorted first, so a cosmetic
representation difference never masks — or fakes — a real one.)

---

## Why the gate is non-circular

The failure mode of every "the AI tested its own work" demo is circularity: the
model writes the code *and* the tests, so the tests encode the same
misunderstanding as the code, and both agree while both are wrong.

```mermaid
sequenceDiagram
    participant O as Original procedure
    participant G as Golden store
    participant A as AI agent
    participant S as Generated service
    participant D as Differential gate

    Note over O,G: happens FIRST, no model involved
    O->>G: run on seeded data, capture output

    Note over A,S: model runs LATER, never sees the original's runtime
    A->>S: generate .NET + Mongo service

    Note over S,D: the judgment
    S->>D: run generated service, capture output
    G->>D: golden output (the independent oracle)
    D-->>A: PASS only if outputs match
```

Because the golden output is frozen before the agent starts, there is no path for
the model to influence the oracle. The oracle is a fact about the *original
system*, not an opinion the model helped form.

One more guard: the MongoDB side of the comparison is seeded by **fixed,
committed migration code** — a pure function of the relational seed, written
before any conversion — so we don't quietly relocate the oracle problem into a
hand-fitted document store.

---

## Built on Claude Code — the four primitives

This is where "AI engineering" stops being a slogan. Each stage of the pipeline is
a real Claude Code mechanism, not a renamed function. A reviewer who knows Claude
Code opens `.claude/` and recognizes their own tools.

```mermaid
flowchart TB
    subgraph claude[".claude/ — the real engineering"]
        direction TB
        agents["<b>Subagents</b><br/>.claude/agents/*.md<br/><i>separated context per role</i>"]
        skills["<b>Skills</b><br/>.claude/skills/*<br/><i>conversion standards as versioned files</i>"]
        hooks["<b>Hooks</b><br/>.claude/settings.json<br/><i>gate every transition automatically</i>"]
    end
    tools["<b>Tools</b><br/>gates/*.sh (Bash today, MCP later)<br/><i>deterministic judgment, not the LLM's</i>"]

    hooks -->|PostToolUse: build| tools
    hooks -->|Stop: differential| tools
    hooks -->|PreToolUse: scope| tools
    agents -->|invoke| skills
    agents -->|run| tools
```

| Primitive | Where it lives | What it proves |
| --- | --- | --- |
| **Subagents** | `.claude/agents/{analyst,implementer,test-author,reviewer}.md` | Context separation is built in, not imitated. The `analyst` is read-only and writes a spec; the `test-author` writes tests without seeing what was convenient for the `implementer`. |
| **Skills** | `.claude/skills/*` | Conversion knowledge (how to map `decimal` → `Decimal128`, how to model a result set as a document) lives in versioned files the `reviewer` checks against — not in an ephemeral prompt. |
| **Hooks** | `.claude/settings.json` | `PostToolUse` builds after every write; `Stop` runs the differential before the agent may finish; `PreToolUse` blocks writes outside allowed folders. Gates run *in the loop*, not after the fact. |
| **Tools** | `gates/*.sh` (Bash now; an MCP server is a planned stretch) | The gate is a deterministic tool the agent *calls* — the model never grades itself. |

The harness runs Claude Code **headless** (`claude -p …`) once per procedure and
collects the real token cost from each run, so the reported numbers come from
actual agent executions, not mocks.

---

## What a reviewer will find here

The repository is designed to be judged **without running it** — the run path
exists to make the numbers falsifiable, not to be the experience. Follow one
conversion end to end, entirely in committed files:

```
corpus/procs/<Proc>.sql          →  the original input
generated/<Proc>Service.cs        →  what the agent produced
corpus/golden/<Proc>.json         →  the oracle, captured before the agent
evals/results/run-*.json          →  the per-proc verdict and cost
```

*(These paths are the target layout; they populate as the implementation lands.)*

---

## Reproduce (for the one reviewer who runs it)

Standing the whole thing up is deliberately production-realistic and therefore
heavy: it restores a public sample database and runs a real agent.

```sh
cp .env.example .env         # add your model API key; .env is gitignored
docker compose up -d         # SQL Server on :11433, MongoDB on :37017
./corpus/restore.sh          # restore + seed the sample DB (pinned .bak, SHA-checked)
./gates/verify.sh            # build + unit + differential against committed output
                             #   → reproduces the published table, with NO model calls
./run.sh                     # optional, PAID: re-run the agent end to end
                             #   → lands with the Phase-4 harness; see docs/tasks/
```

`verify.sh` is the audit: it regenerates the reported results from committed
artifacts without calling any model, and it exists today. Regeneration
(`run.sh`) is a separate, opt-in, paid command that lands with the Phase-4
harness (`evals/harness.py`) — so nothing here surprises you with a bill, and
nothing claims to run before it does.

Ports `11433` / `37017` are non-standard on purpose, to avoid colliding with a
SQL Server or MongoDB you may already run locally.

---

## What this is *not*

Stating the scope limits up front is credibility, not modesty:

- **Not a transpiler.** A deterministic SQL-to-C# converter would be *less* AI, not
  more. The point is trusting a model where a transpiler can't reach (idiomatic
  service code, document modeling, semantic intent).
- **Not a benchmark of "how good the AI is."** It measures whether the *harness*
  catches the AI when it's wrong, and what that costs.
- **Not a biography.** This is a demonstration artifact. It carries no real client,
  product, or engagement data. The corpus is the public MIT-licensed
  WideWorldImporters sample. Any magnitudes here are the demo's own, measured on
  the demo — they do not stand in for figures from any real engagement.

---

## Layout

```
.claude/            the engineering — subagents, skills, hooks (the hero)
  agents/           analyst · implementer · test-author · reviewer
  skills/           conversion standards the reviewer checks against
  settings.json     hooks that gate each transition
corpus/
  procs/            original T-SQL procedures (the input)
  golden/           output captured from the originals, before any model
  seed/             relational seed + fixed migration to the Mongo seed
gates/              build · unit · differential · verify (deterministic tools)
generated/          what the agent produced (the vehicle's output)
evals/              the harness, the method, and the results
docs/               architecture and decision records (ADRs)
demo/               a guided, step-by-step walkthrough (open demo/index.html)
```

---

## Documentation

Everything, in reading order, is indexed in **[`docs/README.md`](docs/README.md)**
— the architecture, the seven ADRs, the pipeline's retry protocol, the eval
preregistration, and the corpus provenance. New here? The **[`demo/`](demo/)**
walkthrough is the fastest way in.

---

## License

[MIT](LICENSE). The corpus is the public MIT-licensed WideWorldImporters sample
(see [`corpus/SOURCE.md`](corpus/SOURCE.md)); this repository carries no real
client, product, or engagement data.
