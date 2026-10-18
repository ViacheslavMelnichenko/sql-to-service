# Design — AST feature-extraction that grounds the LLM conversion

**Date:** 2026-10-18
**Status:** proposed (awaiting review)
**Owner:** Viacheslav Melnichenko

> **Укр. резюме (one-paragraph):** Додаємо детерміновану стадію *перед* аналітиком:
> парсер `sqlglot` розбирає кожну T-SQL процедуру в AST і випускає структуровану
> **feature card** (`generated/<Proc>.features.json`) — факти про joins (INNER/LEFT),
> `TOP`+`ORDER BY`, `FOR JSON AUTO`, decimal-колонки, `LIKE`/`CONCAT`, temporal. Ця
> картка (1) **заземлює** аналітика структурованими фактами, (2) **крос-перевіряється**
> reviewer-ом проти спеки/коду, (3) **наочно показується** у двомовному demo-слайді
> для PM. Це НЕ транспайлер — C# не генерується; це детермінований аналіз, що робить
> LLM-крок спостережуваним і перевірюваним, посилюючи головну тезу репозиторію.

---

## 1. Problem & motivation

The repository is a mature POC that proves *"an unreliable model can be trusted on a
migration task, because an independent oracle catches its mistakes."* Today the
conversion pipeline (`analyst → implementer → test-author → reviewer`) feeds the model
the **raw `.sql` text** plus the golden output. There is **no deterministic structured
analysis** of the T-SQL at all — no parser, AST, tokenizer, or IR. Every semantic trap
(INNER vs LEFT join, `TOP` applied after `ORDER BY`, `FOR JSON AUTO` alias-nesting,
decimal columns, `CONCAT` null-swallowing, temporal windows) is left to the model's
reading of the text, guided only by prose skills.

Two consequences this design addresses:

1. **Best-practice gap.** A production-grade AI pipeline *grounds* the model with a
   deterministic structured extract instead of raw text, reducing hallucination and
   making the model's job narrower and more auditable.
2. **Demo / stakeholder gap.** The pipeline's intelligence is invisible to a non-expert
   (e.g. a project manager). There is no artifact that visibly says *"the AI did not
   guess from text — it first extracted the structure deterministically, then reasoned,
   then was verified independently."*

**Goal:** add a deterministic AST-based **feature-extraction stage** that grounds the
LLM and is shown visually — without turning the project into a transpiler.

### Non-goals (YAGNI)

- **Not** generating C# from the AST (that would be a transpiler; see ADR-0008).
- **Not** converting the remaining 11/14 procedures or completing the eval to k=3 —
  a separate, model-paid track outside this scope.
- **Not** changing the non-circular gate, the golden capture, or the Mongo seed.

---

## 2. Thesis consistency (why this is not a transpiler)

The architecture (`docs/architecture.md` §6) and the README deliberately reject a
deterministic transpiler: *"it would be less AI, not more."* This design is consistent:

- The extractor **never emits C#** and never decides *how* to convert. It only reports
  **what semantic features are present**, as facts.
- Correctness is still established downstream by the **non-circular differential gate**,
  not by the extractor.
- The feature card is to the *input* what the golden is to the *output*: a deterministic,
  model-free artifact derived purely from a committed source (`corpus/procs/<Proc>.sql`
  and the schema in `corpus/seed/relational.sql`). It is auditable and reproducible at
  $0, exactly like the golden.

The role of the extractor is **grounding + observability**, not translation. It makes the
LLM step *narrower* (reason from extracted facts) and *checkable* (reviewer confirms every
extracted feature is addressed).

---

## 3. Architecture

### 3.1 New data flow

```
corpus/procs/<Proc>.sql ─┐
                         ├─▶ corpus/extract-features.py ─▶ generated/<Proc>.features.json
corpus/seed/relational.sql ┘   (sqlglot, deterministic, $0, no model)        │
                                                                              ▼
                                           analyst reads features.json FIRST (grounding)
                                                 → generated/<Proc>.spec.md
                                                 → implementer → test-author
                                                 → reviewer cross-checks spec/code vs features.json
                                                 → differential gate (unchanged)
```

The extractor runs **before the model** in the live harness, and its output is
**committed for all 14 procs** (cheap, since it's model-free).

### 3.2 Component: `corpus/extract-features.py`

Pure function: `(sql_text, schema_types) → feature_card`. CLI: takes a proc name (or
`--all`), reads `corpus/procs/<Proc>.sql`, writes `generated/<Proc>.features.json`.

**Parsing:** `sqlglot.parse_one(sql, dialect="tsql")`, walking the AST with
`expression.find_all(...)`.

**Schema awareness (the differentiator):** parse `corpus/seed/relational.sql`'s
`CREATE TABLE` statements once to build a `{table.column → sql_type}` map, so the
extractor can resolve which **output columns are `decimal`/`money`** — not just guess
from names.

**Detectors (each maps to a skill):**

| Feature `kind`        | What it detects                                              | Skill |
|-----------------------|-------------------------------------------------------------|-------|
| `join.inner`          | each INNER JOIN: left/right table + aliases (drops rows)     | tsql-semantics |
| `join.left`           | each LEFT OUTER JOIN: keeps row + null-fills                 | tsql-semantics |
| `top_order`           | `TOP(@n)` present + the `ORDER BY` columns (order-then-limit)| tsql-semantics |
| `for_json`            | `FOR JSON AUTO/PATH` + `ROOT(name)` + alias-nesting note     | document-modelling |
| `decimal_column`      | output columns resolved to `decimal`/`money` via schema map  | decimal-mapping |
| `like_concat`         | `WHERE ... LIKE` combined with `CONCAT(...)` (null-swallow)  | tsql-semantics |
| `temporal`            | `FOR SYSTEM_TIME`, `*_Archive` refs, cursor over history     | tsql-semantics |
| `param`               | procedure parameters + declared types                        | — |

**Output contract** (`generated/<Proc>.features.json`):

```json
{
  "proc": "Website.SearchForCustomers",
  "generated_by": "corpus/extract-features.py (sqlglot, dialect=tsql)",
  "params": [{"name": "@SearchText", "type": "nvarchar(1000)"}, ...],
  "tables": [{"name": "Sales.Customers", "alias": "c"}, ...],
  "output_shape": "for-json",
  "features": [
    {"kind": "join.inner", "detail": "Sales.Customers c INNER JOIN Application.Cities ct",
     "skill": "tsql-semantics", "risk": "high",
     "note": "a customer with no city is dropped"},
    ...
  ]
}
```

`risk` ∈ {`high`,`medium`,`low`} drives both the reviewer gate and the demo highlight.

**Determinism:** output keys sorted, stable ordering, `\n` endings — mirrors the
`canonicalise.py` discipline so re-runs are byte-identical.

### 3.3 Pipeline wiring

- **`.claude/agents/analyst.md`:** instruct the analyst to read
  `generated/<Proc>.features.json` **first** as deterministic grounding, and to treat
  it as fact (not opinion). The spec must address every `high`-risk feature.
- **`.claude/agents/reviewer.md`:** add a checklist step — every feature in
  `features.json` must be accounted for in the spec and the generated code (e.g. a
  `join.left` → code keeps the null-contact row; a `decimal_column` → no float cast).
- **`evals/harness.py`:** before the live conversion of a proc, run
  `extract-features.py <proc>` (deterministic, outside the model) so `features.json`
  exists when the analyst starts. Mirrors how golden is produced outside the model.

### 3.4 Gate: `gates/features-check.sh` (lightweight, deterministic)

A small gate (composed into `verify.sh`) that asserts, per proc in the manifest:
- `generated/<Proc>.features.json` exists and is schema-valid JSON;
- re-running the extractor produces a **byte-identical** card (determinism, mirrors
  `verify-stable.sh`);
- every `high`-risk feature's `skill`/`note` is non-empty.

The **semantic** cross-check (does the code actually honor each feature?) stays the
reviewer's responsibility — kept out of the deterministic gate to avoid brittle
string-matching, consistent with how the project separates mechanical gates from
judgment.

### 3.5 Tests

`corpus/tests/test_extract_features.py` (xUnit-of-Python, matching
`corpus/tests/test_pure_tools.py` style): feed small T-SQL snippets, assert the
extractor classifies joins, detects `TOP`+`ORDER BY`, resolves a decimal column from a
tiny schema, flags `FOR JSON AUTO`, and is deterministic. Pure unit tests, no engines.

---

## 4. Demo (stakeholder-facing)

### 4.1 New interactive "Feature extractor" slide (`demo/index.html`)

Self-contained, vanilla JS, no external deps (matches the existing deck). A **split
view**:

- **Left:** the raw `.sql` of a selectable proc (dropdown over the 14 procs).
- **Right:** the extracted **feature card** rendered as highlighted chips grouped by
  risk — INNER/LEFT joins, `TOP`+`ORDER`, `FOR JSON AUTO`, decimal columns, temporal —
  each chip linking (in text) to the skill that handles it.
- A one-line caption framing the four moves: **raw text → deterministic extraction →
  grounded AI → independent verification.**

Data source: the committed `features.json` embedded inline as a JS object (generated
once, pasted in — consistent with how the deck embeds real captured output). Bilingual
via the existing ENG/UA toggle.

### 4.2 Updated flow diagram

Add the extraction stage to the deck's `.flow` pipeline diagram and to the README /
`architecture.md` mermaid flowcharts: a new deterministic box *"feature-extract
(sqlglot)"* feeding the analyst, drawn in the same style as the golden "oracle lane"
(deterministic, model-free).

---

## 5. Documentation (EN + UK)

- **`docs/adr/0008-ast-feature-grounding.md`** (+ `.uk.md`): the decision — deterministic
  AST extraction grounds the LLM; explicitly *why it is not a transpiler*; how it
  strengthens the thesis; its determinism/auditability.
- **`docs/architecture.md`** (+ `.uk`): new subsection + updated diagram for the stage.
- **`README.md`** (+ `.uk`): mention the grounding stage in "The flow, end to end" and
  the primitives table; add the extractor to the Layout.
- **`docs/README.md`** (+ create missing **`docs/README.uk.md`**): index the new ADR.
- **`demo/README.md`:** fix the two known inconsistencies while here —
  `5/5 → 12/12` mutants, and the stale "ten steps" → the actual slide set (now +1).

---

## 6. Units & interfaces (isolation)

| Unit | Does | Used via | Depends on |
|------|------|----------|------------|
| `extract-features.py` | SQL text → feature card | CLI + `features.json` JSON contract | `sqlglot`, `relational.sql` schema |
| `features.json` | the contract | read by analyst, reviewer, gate, demo | — (frozen artifact) |
| `features-check.sh` | deterministic presence/determinism gate | `verify.sh` | `features.json`, extractor |
| demo slide | render a card | reads embedded JSON | `features.json` shape |

Every consumer touches only the **`features.json` contract**, so the extractor's
internals can change without breaking the analyst, reviewer, gate, or demo.

---

## 7. Dependencies & risks

- **New dependency:** `sqlglot` (pip). Add to the project's Python deps / `.env.example`
  note and the extractor's import guard (clear error if missing). Pin a version.
- **Risk — sqlglot T-SQL coverage:** the temporal procs use `FOR SYSTEM_TIME` and
  cursors sqlglot may parse partially. Mitigation: detectors are **best-effort and
  additive** — if a construct doesn't parse cleanly, emit a `parse_note` feature rather
  than crashing; the card degrades gracefully and the demo still shows what parsed.
- **Risk — decimal resolution without full type inference:** schema map covers base-table
  columns; computed/renamed columns may not resolve. Mitigation: mark unresolved decimals
  `medium` risk with a note, don't over-claim.
- **Hooks:** the repo's `guard-path`/`stop-differential` hooks are **temporarily
  disabled** during this work (they gate the per-proc conversion loop, not repo
  engineering) and **restored at the end** from `.claude/settings.json.bak`.

---

## 8. Acceptance criteria

1. `python corpus/extract-features.py --all` writes a valid, deterministic
   `features.json` for all 14 procs ($0, no model).
2. The three converted procs' cards correctly classify their known traps
   (SearchForCustomers: INNER+LEFT+TOP/ORDER+FOR JSON+like_concat;
   GetTransactionUpdates: temporal/decimal; GetStockHoldingUpdates: decimal).
3. `corpus/tests/test_extract_features.py` passes.
4. `gates/features-check.sh` passes for the manifest procs and is wired into `verify.sh`.
5. analyst/reviewer definitions reference the card; harness runs the extractor pre-model.
6. The demo has a working, bilingual interactive feature-extractor slide and an updated
   flow diagram.
7. ADR-0008 (EN+UK), architecture/README updates (EN+UK), `docs/README.uk.md`, and the
   `demo/README.md` fixes are in place.
8. Hooks restored; `verify.sh` still green on the three converted procs.
