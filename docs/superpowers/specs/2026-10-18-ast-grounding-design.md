# Design — Deterministic AST feature extraction (grounding + observability)

**Date:** 2026-10-18
**Status:** approved (revised after a four-agent expert review; scope narrowed to demo-first)
**Owner:** Viacheslav Melnichenko

> **Укр. резюме (one-paragraph):** Додаємо детерміновану, model-free стадію аналізу:
> парсер `sqlglot` розбирає кожну T-SQL процедуру в AST і випускає **feature card**
> (`corpus/features/<Proc>.features.json`) — *факти* про joins (INNER/LEFT), `TOP`+`ORDER
> BY`, `FOR JSON`, decimal-колонки (через схему), `LIKE`/`CONCAT`, temporal. Картка —
> це **спостережуваність + заземлення**, а не влада над коректністю: differential vs
> golden лишається єдиним суддею. У цьому обсязі картка НЕ вшивається в analyst/reviewer
> і НЕ в `verify.sh`; вона наочно показується у двомовному demo-слайді для PM. Це НЕ
> транспайлер — C# не генерується.

---

## 0. What changed after review (and why)

Four expert agents reviewed the first draft (sqlglot-feasibility, AI-pipeline best
practices, demo/PM, adversarial). Their consensus reshaped the scope. The load-bearing
corrections, each folded into this revision:

1. **A feature card is *not* an oracle.** The golden is an *observation of the real
   system* (the original proc executed on a seed); a card is a second static re-derivation
   verified only by its own byte-stability. Determinism ≠ correctness. So the card gets
   **no authority over the conversion** — it is grounding/observability only.
2. **No new conversion benefits from it yet.** All three converted procs are already green;
   the other 11 are out of scope. Wiring the card into `analyst`/`reviewer` would grant it
   authority it has not earned (0 measured analyst misses). → **Demo-first / out-of-loop.**
   Pipeline wiring is deferred behind a *measured* analyst miss (§7).
3. **Do not touch `verify.sh`.** It is the authoritative, model-free, stdlib-only
   reproduce-the-numbers script. Importing `sqlglot` into it would make a pip package a
   prerequisite of the headline verdict and import parser-version flake. → The new gate is
   **standalone**, never composed into `verify.sh`.
4. **`*.uk.md` is gitignored** (`.gitignore:33`, "never committed"). → **No committed
   Ukrainian doc files.** Bilingualism lives only in the demo's EN/UA toggle, where the
   repo already keeps it.
5. **Hooks:** the committed `.claude/settings.json` *has* the three hooks; they were only
   disabled in the working tree for this repo-engineering. → Restore via
   `git checkout .claude/settings.json` (the `.bak` is itself gitignored). No hook changes
   ship.
6. **Facts, not judgment.** A card that emits per-proc `risk` and narrative `note` is "the
   analyzer the architecture rejected." → The card emits **facts + locations only**; risk,
   skill routing and the plain-English consequence live in a **static per-`kind`
   catalogue**, not in the per-proc output.

---

## 1. Problem & motivation

The repository proves *"an unreliable model can be trusted on a migration task, because an
independent oracle catches its mistakes."* Today the pipeline feeds the model the **raw
`.sql` text** plus the golden. There is **no deterministic structured analysis** of the
T-SQL — no parser, AST or IR. That is a real gap against best-practice AI pipelines, and it
leaves the pipeline's intelligence **invisible to a non-expert (a PM)**: nothing visibly
says *"the AI did not guess from text — structure was extracted deterministically first,
then the model reasoned, then an independent oracle verified."*

**Goal (this scope):** add a deterministic, model-free, `$0` AST **feature-extraction
tool** and make it **visible** in the demo — without granting it any authority over
correctness and without turning the project into a transpiler.

### Non-goals (YAGNI)

- **Not** generating C# from the AST (that is a transpiler; ADR-0008 records why we don't).
- **Not** wiring the card into `analyst`/`reviewer`/`verify.sh`/the harness in this scope
  (deferred behind a measured miss — §7).
- **Not** committing any `*.uk.md` file (gitignored by policy).
- **Not** converting the remaining 11 procs or completing the eval to k=3.
- **Not** changing the non-circular gate, golden capture, or Mongo seed.

---

## 2. Thesis consistency (why this is not a transpiler)

- The extractor **never emits C#** and never decides *how* to convert. It reports **what
  semantic features are present**, as facts with source locations.
- Correctness stays with the **non-circular differential gate** — untouched.
- The card is to the *input* what a *log* is, not what the *golden* is: a deterministic,
  model-free, `$0` artifact derived from committed sources (`corpus/procs/<Proc>.sql` +
  `corpus/seed/relational.sql`). It is auditable and reproducible, but it is **not an
  oracle** and nothing in the correctness loop reads it (proven mechanically — §3.4 #5).

---

## 3. Architecture

### 3.1 Data flow (this scope)

```
corpus/procs/<Proc>.sql ─┐
                         ├─▶ corpus/extract-features.py ─▶ corpus/features/<Proc>.features.json   (model-free zone,
corpus/seed/relational.sql ┘   (sqlglot, deterministic, $0, no model)        │                     beside corpus/golden/)
                                                                              ├─▶ demo/features-data.js  (derived; gate-synced)
                                                                              ▼
                                                                  demo/index.html  "Feature extractor" slide
```

The card lives in **`corpus/features/`** — the model-free zone next to `corpus/golden/`,
*not* in `generated/` (which is the model's output directory). It is **not** consumed by
any pipeline stage in this scope.

### 3.2 Component: `corpus/extract-features.py`

Pure-ish function `(sql_text, schema_types) → feature_card`. CLI:
- `extract-features.py <Proc>` → write `corpus/features/<Proc>.features.json`
- `extract-features.py --all` → all 14 procs
- `extract-features.py --emit-demo` → write `demo/features-data.js` from the 14 cards

**Parsing (feasibility-verified fixes):**
- Pre-strip `RETURN\s+\d+\s*;` before `parse_one(sql, dialect="tsql")` — without this,
  `parse_one` crashes on all 9 `Integration.Get*Updates` procs (their body ends `RETURN 0;`).
- Wrap in try/except: on failure emit `parse_status:"degraded"` + a `parse_notes` entry
  instead of crashing (graceful degradation, verified).

**Detectors — facts only (no risk/note in output):**

| Feature `kind`   | Detection (AST unless noted)                                              |
|------------------|--------------------------------------------------------------------------|
| `join.inner`     | `Join(side=None, kind=INNER)` → left/right tables + aliases; **dedup** (temporal procs repeat joins 3× via cursors) |
| `join.left`      | `Join(side=LEFT, kind=OUTER)` → tables + aliases; dedup                   |
| `top_order`      | `select.args['limit']` present **and** `select.args['order']` columns     |
| `for_json`       | `select.args['for_']` present; mode (`AUTO`/`PATH`) + `ROOT(name)` via **regex fallback** (sqlglot doesn't structure the option) |
| `decimal_column` | output column resolved to `{DECIMAL, MONEY, SMALLMONEY}` via schema map (§3.3); honors enclosing `exp.Cast` target type |
| `like_concat`    | `exp.Like` co-present with `exp.Concat`                                   |
| `temporal`       | `FOR SYSTEM_TIME` from `Table.args['version']` (AST); `*_Archive` refs and `DECLARE CURSOR`/`FETCH` via **regex** (they fall to `exp.Command`) |
| `param`          | parameters + declared types from the `Create` node                        |

### 3.3 Schema-aware decimal resolution (kept; hardened; 3-proc scope)

Empirically the differentiator works for the converted procs. Hardening (all feasibility-verified):
- Build the `{table.column → DataType.Type}` map by **isolating each `CREATE TABLE` block**
  (split on `GO`) and `parse_one` each — a whole-file IGNORE parse recovers only 20/30.
- Match on the **enum set** `{DECIMAL, MONEY, SMALLMONEY}`, never the string `"decimal"`
  (sqlglot renders `decimal(18,2)` as `NUMERIC`; `MONEY` is a distinct enum).
- Honor an enclosing `exp.Cast` target type so `CAST(sit.Quantity AS int)` is **not**
  flagged decimal.
- A **missing** schema key resolves to `"unknown"`, **never** "not decimal".
- Computed/`CASE`/`COALESCE` outputs are marked `resolved:false` with
  `"still-money-bearing"` guidance in the catalogue — "unresolved" must not read as "not
  decimal".

### 3.4 Gate: `gates/features-check.sh` (standalone — NOT in `verify.sh`)

Mirrors `verify-stable.sh` discipline; run on its own, never from `verify.sh`:
1. **Presence & shape:** each of 14 `corpus/features/<Proc>.features.json` exists, is valid
   JSON, carries `schema_version` and `sqlglot_version`.
2. **Determinism:** re-run the extractor into a temp dir; assert **byte-identical** to the
   committed cards (pinned sqlglot makes this stable).
3. **Demo sync:** re-emit `demo/features-data.js`; assert **byte-identical** to the
   committed file — the demo has no hand-pasted second copy.
4. **Taxonomy (teeth):** every `feature.kind` in every card exists in the catalogue, and
   every catalogue `skill` maps to a real `.claude/skills/<skill>/` dir (or `—`). This is
   the one mechanical check that earns its keep: it catches skill↔extractor drift.
5. **Out-of-authority proof (teeth, ADR-0006 style):** assert **no** file in the
   correctness loop (`.claude/agents/*.md`, `gates/verify.sh`, `gates/differential.sh`)
   references `corpus/features` — proving the card cannot change the differential verdict.
   This is the demo-first equivalent of "corrupting the card must not flip the verdict."

### 3.5 Output contract (`corpus/features/<Proc>.features.json`)

```json
{
  "schema_version": 1,
  "sqlglot_version": "30.23.0",
  "proc": "Website.SearchForCustomers",
  "generated_by": "corpus/extract-features.py",
  "parse_status": "ok",
  "params": [{"name": "@SearchText", "type": "NVARCHAR(1000)"}],
  "tables": [{"name": "Sales.Customers", "alias": "c"}],
  "output_shape": "for-json",
  "features": [
    {"kind": "join.inner", "detail": "Sales.Customers c -> Application.Cities ct"},
    {"kind": "decimal_column", "detail": "ct.TransactionAmount : DECIMAL(18,2)", "resolved": true}
  ],
  "parse_notes": []
}
```

No `risk`/`note` per feature. Determinism via
`json.dumps(card, sort_keys=True, ensure_ascii=False, indent=2) + "\n"`.

### 3.6 Static per-`kind` catalogue

A single committed source of interpretation (`KIND_CATALOGUE` in the extractor, emitted
into `demo/features-data.js`): `kind → {skill, risk, consequence_en, consequence_uk}`.
Leads with the plain-English consequence (demo/PM review): e.g. `join.inner → "a customer
with no city is silently dropped"`. This is where the EN/UA chip text comes from — no
English-only `note` in the card, no second translation surface.

### 3.7 Tests: `corpus/tests/test_extract_features.py`

Stdlib `unittest`, matching `test_pure_tools.py`. Skips cleanly if `sqlglot` is absent so
the stdlib-only tools container stays green; runs fully where sqlglot is present. Covers:
RETURN-strip lets all shapes parse; INNER vs LEFT classification; join dedup; `TOP`+`ORDER`
detection; decimal resolved from a tiny schema; `CAST(... AS int)` is **not** decimal;
`FOR JSON` + ROOT; `like_concat`; determinism (two runs byte-identical); degraded parse
emits `parse_note` rather than raising.

---

## 4. Demo (stakeholder-facing)

### 4.1 New interactive "Feature extractor" slide (`demo/index.html`)

Inserted in **both** language sets at the same ordinal — between **"The pipeline"** and
**"The gates"** (EN) / **"Пайплайн"** and **"Перевірки"** (UK). Self-contained vanilla JS,
no external deps. A **split view**:
- **Left:** the raw `.sql` of a selectable proc (dropdown).
- **Right:** the card rendered as chips, **each leading with the plain-English
  consequence** (not the SQL construct), grouped by the catalogue's `risk`, with the skill
  named. Degraded cards show a visible "⚠ partial parse" banner — graceful degradation as a
  feature, shown honestly.
- Caption nests into the deck's existing three-beat story as **extract → ground → verify**,
  and states **`$0`, no model** (ties to the "AI economics" slide). It does **not** compete
  with the deck's canonical "four moves" sentence, and it does **not** claim the three
  already-converted procs were retroactively grounded — it is framed as "the deterministic
  analysis the pipeline can now surface," illustrated on existing procs.

**Data source:** `demo/features-data.js` (`window.FEATURES = {…};`), **emitted by the
extractor** and **gate-synced** (§3.4 #3) — loaded via `<script src="features-data.js">`
(works under `file://`, unlike `fetch`). No hand-paste.

### 4.2 Updated flow diagram

Add a deterministic **"feature-extract (sqlglot · $0)"** box to the deck's `.flow` diagram
(and the README/architecture mermaid), drawn in the model-free style — feeding *observation*
to the side of the pipeline, explicitly **not** on the correctness path.

---

## 5. Documentation (EN only committed)

- **`docs/adr/0008-ast-feature-grounding.md`** (EN): the decision — deterministic AST
  extraction as grounding/observability; *why it is not a transpiler*; why it holds **no
  authority** over correctness; the deferral of pipeline wiring behind a measured miss.
  Phrased as "this ADR records…", not cited as prior authority elsewhere.
- **`docs/architecture.md`:** a short subsection + the model-free box in the diagram.
- **`README.md`:** one mention in the flow and the primitives/layout, clearly labeled
  observability (not a gate).
- **`docs/README.md`:** index ADR-0008.
- **`demo/README.md`:** fix the two real inconsistencies — `5/5 → 12/12` mutants, and the
  slide count (now **16** per language, not "ten steps").

(Ukrainian translations of these docs remain private working copies per `.gitignore` and
are out of scope to commit.)

---

## 6. Units & interfaces

| Unit | Does | Used via | Depends on |
|------|------|----------|------------|
| `extract-features.py` | SQL → card; `--emit-demo` → demo data | CLI | `sqlglot` (pinned), `relational.sql` |
| `corpus/features/*.json` | the fact contract | demo data emit, gate | — (model-free artifact) |
| `demo/features-data.js` | derived demo data | `demo/index.html` | cards (gate-synced) |
| `features-check.sh` | presence/determinism/sync/taxonomy/out-of-authority gate | standalone | cards, extractor |
| demo slide | render a card | reads `window.FEATURES` | demo-data shape |

Nothing in the conversion loop depends on any of these — by design and by mechanical check.

---

## 7. Deferred: pipeline wiring (evidence-gated)

Wiring the card into `analyst`/`reviewer` is **described but not activated**. It turns on
only when the harness records a **concrete analyst miss the card would have caught**. At
that point the precedence rule is fixed: **golden > skills > features.json (hint)** — the
card is never "fact," never outranks a skill or the golden. Until then, activating it would
grant unearned authority (review consensus).

---

## 8. Dependencies & risks

- **Dependency:** `sqlglot`, pinned in a new **`corpus/requirements.txt`**
  (`sqlglot==30.23.0`). The extractor guards the import with a clear error. `sqlglot_version`
  is recorded **inside** each card; a version bump is an explicit "regenerate + review the
  diff" event, caught by the determinism gate.
- **Risk — parser drift reddening a gate:** contained — `features-check.sh` is standalone,
  so parser flake can never redden `verify.sh`/the correctness verdict.
- **Risk — decimal resolution gaps:** computed/renamed columns resolve to
  `resolved:false` + "still-money-bearing"; missing schema keys → "unknown"; never silently
  "not decimal".
- **Hooks:** unchanged in the committed repo. Restored via `git checkout
  .claude/settings.json` at the end of this work; the `.bak` is deleted.

---

## 9. Acceptance criteria

1. `python corpus/extract-features.py --all` writes a valid, deterministic card for **all
   14** procs (`$0`, no model); no proc crashes the parse.
2. The three converted procs' cards carry their known facts: SearchForCustomers →
   `join.inner` + `join.left` + `top_order` + `for_json` + `like_concat`;
   GetTransactionUpdates → `join.left` + ≥4 `decimal_column` + UNION-ALL note;
   GetStockHoldingUpdates → `LastCostPrice` `decimal_column`. Asserted by a committed
   expected-fact fixture the test diffs against (mechanical, not eyeball).
3. `corpus/tests/test_extract_features.py` passes (and skips cleanly without sqlglot).
4. `gates/features-check.sh` passes and is **not** referenced by `verify.sh`.
5. The demo has a working bilingual interactive "Feature extractor" slide (16 per language)
   loading gate-synced `demo/features-data.js`; the flow diagram shows the model-free box.
6. ADR-0008 (EN), architecture/README/docs-index updates, and the `demo/README.md` fixes
   are in place. No `*.uk.md` is committed.
7. Hooks restored (committed `settings.json` intact); `.bak` removed.
8. `corpus/features/` is referenced by **no** file in the correctness loop (mechanically
   asserted by the gate).
