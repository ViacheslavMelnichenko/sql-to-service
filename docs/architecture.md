# Architecture

This expands the three README diagrams into the reasoning behind them. The README
answers *what*; this answers *why it is shaped this way*. It is a permanent
document — it outlives the task tracker.

The whole design serves one claim: **that an unreliable model can be trusted on a
migration task, because an independent oracle catches its mistakes and a harness
measures that it did.** Every structural decision below is downstream of that.

---

## 1. The shape of the problem

Converting a T-SQL stored procedure into a .NET + MongoDB service is a task a model
can *attempt* easily and get *subtly wrong* often: an off-by-one in pagination, a
dropped optional filter, a relevance ordering that looks right but isn't, a decimal
that loses precision crossing into `Decimal128`. None of these fail loudly. All of
them fail a customer.

So the engineering problem is not "convert" — it's "**know when the conversion is
wrong**, cheaply, without a human reading every line." That is an oracle problem,
and it drives everything.

---

## 2. The oracle, captured before the AI

```mermaid
flowchart LR
    seed[(Relational seed<br/>branch-covering)] --> proc[Original T-SQL]
    seed --> tomongo[to_mongo.py<br/><i>fixed, mechanical</i>]
    proc -- capture --> golden[(Golden JSON)]
    tomongo --> mongo[(Mongo seed)]

    golden -.->|independent oracle| diff{differential}
    gen[Generated service] --> diff
    mongo --> gen
    diff -->|verdict| out[per-proc result]
```

The golden output is captured from the **original procedure**, on a **branch-
covering seed**, **before any model runs** (ADR-0001). It is a fact about the
original system. The model cannot influence it because it does not exist yet when
the golden is frozen.

Two subtleties the diagram encodes:

- **Both sides descend from the same seed.** The golden comes from the original
  T-SQL over the relational seed; the Mongo data comes from a **fixed mechanical
  migration** (`to_mongo.py`) of the *same* relational seed (ADR-0003). Neither
  side is fitted to the other, so the comparison stays honest. If we hand-authored
  the Mongo documents, we'd have moved the oracle problem, not solved it.
- **The seed is sized by branch coverage, not volume** (ADR-0002). It exists to
  make every branch produce a *distinguishable* output — proven by the mandatory
  mutation check (ADR-0006), not assumed.

---

## 3. The agent, staged on Claude Code

```mermaid
flowchart TB
    analyst["analyst<br/><i>read-only · writes a spec</i>"]
    implementer["implementer<br/><i>spec → .NET + Mongo</i>"]
    testauthor["test-author<br/><i>separate context · unit tests</i>"]
    reviewer["reviewer<br/><i>checks vs skills</i>"]

    analyst --> implementer --> testauthor --> reviewer
    skills[".claude/skills/*<br/>conversion standards"] -.->|loaded by| reviewer
    reviewer -->|passes to gate| gate[gates/*.sh]

    extract["feature-extract<br/><i>sqlglot · $0 · no model</i>"] -.->|observation only<br/>no stage reads it| cards[(corpus/features/*)]
```

The `feature-extract` box sits deliberately *off* the line — it reads the same T-SQL
and emits a per-proc card of facts, but nothing in the pipeline or the gate reads
those cards. It is drawn disconnected because it *is* disconnected; see §5b.

Four **subagents** with genuinely separated context (ADR-0004), not one prompt in a
loop:

- **`analyst`** reads the T-SQL and writes a specification of *intent*. Read-only —
  it writes no code, so the implementer starts from an understanding, not a
  translation.
- **`implementer`** turns the spec into an idiomatic .NET service over the
  fixed Mongo document model.
- **`test-author`** writes unit tests in a **separate context**, so it doesn't
  encode "what was convenient for the implementer" — it works from the spec.
- **`reviewer`** checks the output against **skills** (`.claude/skills/*`) — the
  conversion standards as versioned files, not advice in a prompt.

The staging is the point: separated context is what stops the code and its tests
from sharing a blind spot. That's also *why the agent's own tests never pass the
gate alone* — they could be wrong in the same direction as the code (ADR-0001).

---

## 4. The gate, in-loop via hooks

```mermaid
flowchart LR
    write[agent writes to generated/] -->|PostToolUse| build{build}
    build -->|ok| more[agent continues]
    stop[agent tries to Stop] -->|Stop hook| diff{differential<br/>vs golden}
    diff -->|pass| done[finish]
    diff -->|fail| retry[feedback → retry, cap 2]
    retry --> write
```

**Hooks** (`.claude/settings.json`) make gating a property of the loop, not a
post-hoc script:

- **`PostToolUse`** builds after every write to `generated/` — a non-compiling
  service never advances.
- **`Stop`** runs the differential before the agent may finish — a conversion that
  doesn't match golden cannot be declared done; the failure is fed back as
  structured feedback and the agent retries (cap 2).
- **`PreToolUse`** blocks writes outside allowed folders — the agent can't wander.
  It guards the file-write tools (`Write`/`Edit`/…) *and*, as defence in depth, a
  `Bash` call that both mutates and names a protected path (`cp`/`mv`/`sed -i`/
  `git checkout`/redirection into `corpus/`, …). That Bash check is a heuristic
  bar-raiser, not a sandbox — the non-bypassable backstop stays a fresh-checkout
  `verify.sh`, which re-derives the numbers from the committed oracle regardless.

The gate-tools themselves are **Bash scripts** (ADR-0005) — the same artifact the
agent calls, the hook invokes, and a human reads. `verify.sh` composes
build + unit + differential and reproduces the published results **with no model
calls**, which is what makes the numbers auditable.

And the gate's authority is **proven, not asserted**: `mutation-check.sh`
(ADR-0006, mandatory) injects known bugs and requires the gate to catch every one.

---

## 5. The harness, measuring honestly

> **Status:** built and running (Phase 4). `evals/harness.py` drives the agent over
> the corpus and has produced its first live sample (`run-001.sample-01.json`,
> snapshot `claude-opus-4-8`); the pre-registered **k=3** distribution is in
> progress (k=1 measured). See [`../evals/results/summary.md`](../evals/results/summary.md).

The harness runs Claude Code **headless** (`claude -p …`) once per procedure and
records, per proc: the differential verdict, retries used, tokens, and cost — and,
one level finer, a **per-attempt** split (each retry's own tokens/cost/turns and a
claude-vs-gate wall-time split) plus a **best-effort per-subagent-stage** token
attribution read from the stream transcript, which degrades honestly (records
`available: false` with a reason) when the transcript lacks the linkage rather than
fabricating a split. It runs
once per **sample**; across the pre-registered `k=3` samples,
[`evals/aggregate.py`](../evals/aggregate.py) reports a **distribution**, flags
`flaky` procedures, and audits that each sample genuinely regenerated (a 0-turn
sample is not an independent measurement). A result with no failures is treated as a
**finding to investigate**, not a win (PREREGISTRATION.md, H3). A naive
single-prompt run is kept as the **control baseline** (B.4).

The one artifact that cannot be faked is the **analysis paragraph** in
`evals/results/summary.md`: what the run showed, read against the prediction —
including, when the sweep is clean, *why* that is a caveat rather than a headline.
Writing it truthfully requires having done the work.

The operational detail — how to actually run this (dry vs live, POSIX vs Windows),
the prerequisites, and the authentication traps — lives in the runbook,
[`../evals/RUNNING.md`](../evals/RUNNING.md).

---

## 5b. Grounding, to the side

`corpus/extract-features.py` parses each procedure with sqlglot (`dialect="tsql"`)
and emits a deterministic **feature card** — the joins by kind, the schema-grounded
decimal outputs, the `FOR JSON` shape, `TOP`/`ORDER` coupling, temporal reads,
parameters. It exists to make the per-proc semantics legible to a reviewer and in
the demo, for `$0` and with no model call.

It is **observability, not an oracle** (ADR-0008). It never emits C#, never decides
*how* to convert, and — the load-bearing part — nothing in the correctness loop
reads its cards. The non-circular differential against the golden stays the sole
judge. That powerlessness is proven the same way the gate's teeth are (ADR-0006):
`gates/features-check.sh` is standalone (never called from `verify.sh`) and fails if
any agent, `verify.sh`, or `differential.sh` so much as references `corpus/features`.
So a card can be wrong, stale, or deleted and the accuracy number does not move.
Wiring the cards into the analyst as grounding is deferred behind a *measured* miss,
never adopted on faith.

## 6. Why not the obvious alternatives

- **Why not a deterministic transpiler?** It would be *less* AI, not more, and it
  can't reach idiomatic service code or document modeling. The point is trusting a
  model where a transpiler can't go.
- **Why not let the AI test itself?** Circular — the tests inherit the code's
  misunderstanding (ADR-0001).
- **Why not hand-author the Mongo data?** It relocates the oracle problem into a
  fitted document store (ADR-0003).
- **Why not trust the gate by design?** Because "should catch" isn't "was shown to
  catch" — the artifact refuses that assertion about the AI, so it can't make it
  about its own gate (ADR-0006).

---

## 7. Decision record

| ADR | Decision |
| --- | --- |
| [0001](adr/0001-non-circular-gate.md) | Golden captured before any model runs |
| [0002](adr/0002-dataset-sizing.md) | Dataset sized by branch coverage, not volume |
| [0003](adr/0003-mechanical-mongo-seed.md) | Mongo seed is a pure function of the relational seed |
| [0004](adr/0004-claude-code-substrate.md) | Built on Claude Code — real agents/skills/hooks/tools |
| [0005](adr/0005-tools-bash-then-mcp.md) | Bash gate-tools now, MCP as a stretch |
| [0006](adr/0006-mutation-validation.md) | Mandatory mutation check proves the gate has teeth |
| [0008](adr/0008-ast-feature-grounding.md) | Deterministic AST feature cards — observability only, proven to hold no authority over the verdict |
