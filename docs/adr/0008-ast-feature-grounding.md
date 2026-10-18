# 0008 — AST feature grounding: deterministic observability, not an oracle

- **Status:** Accepted
- **Date:** 2026-10-18
- **Deciders:** Viacheslav Melnichenko

## Context

Reading a stored procedure for the traps that make a conversion subtly wrong —
which joins drop rows, where money columns are, how `FOR JSON` nests, whether a
`TOP` depends on an `ORDER BY` — is slow and easy to get wrong by eye. A
deterministic parse can surface those facts cheaply. The temptation is then to let
that parse *drive* the conversion, or worse, *judge* it. That temptation is exactly
what this ADR exists to refuse.

The artifact's whole credibility rests on one claim (ADR-0001): the thing that
decides whether a conversion is correct is captured from the original T-SQL
**before any model runs**, so nothing in the generation path can collude with its
judge. A new tool that reads the SQL and emits structured facts is useful — but if
any stage or gate reads those facts, the tool has quietly joined the correctness
path and the non-circularity argument weakens.

## Decision drivers

- Make the per-proc semantics legible — to a reviewer, and in the demo — for `$0`
  and with no model call.
- Do **not** add a second oracle, and do **not** become a transpiler. The point of
  the project is trusting a model where a deterministic translator cannot go; a
  parser that decided *how* to convert would contradict the thesis.
- Keep the non-circular gate (ADR-0001) the **sole** judge, and be able to *prove*
  mechanically that the new tool holds no authority over the verdict.

## Considered options

1. **Wire the extractor into the analyst/implementer as grounding input.** Deferred,
   not rejected — see "Deferral" below. It couples a parser's blind spots into the
   generation path before we have evidence the model actually needs the help.
2. **Use the extracted features as an additional gate.** Rejected — it would be a
   second oracle derived from the same SQL the model reads, reintroducing exactly
   the circularity ADR-0001 removes. "The AST says INNER JOIN" is not independent
   evidence of correct behaviour; the golden is.
3. **A read-only observability tool with zero authority, proven powerless.** Chosen.

## Decision

`corpus/extract-features.py` parses each procedure with **sqlglot** (pinned,
`dialect="tsql"`) and emits a per-proc **feature card** of *facts* —
`corpus/features/<Proc>.features.json`. It is observability, nothing more:

- It never emits C# and never decides **how** to convert — it reports **what** is
  present (joins by kind, schema-grounded decimal outputs, `FOR JSON` shape,
  `TOP`/`ORDER` coupling, `LIKE`/`CONCAT`, temporal/history reads, parameters).
- **Interpretation lives in a static `KIND_CATALOGUE`**, not in the cards: each
  `kind` maps to a risk, the versioned skill that handles it, and a plain-English
  consequence (EN/UK, for the demo). A card stays facts-only; the taxonomy has one
  home.
- It is **deterministic** (mirrors `canonicalise.py`: sorted keys, `\n` endings, no
  wall-clock, no model), so re-running yields byte-identical output. The pinned
  sqlglot version is recorded in every card, so a parser bump is an explicit
  "regenerate and review the diff" event.
- It **degrades honestly**: cursors and `SYSTEM_TIME` that sqlglot cannot fully
  parse fall back to a regex pass and the card is marked `parse_status: degraded`
  with a note — never a silent guess.

Its powerlessness is **proven, not asserted** (ADR-0006 style).
`gates/features-check.sh` is **standalone** — deliberately **not** called from
`verify.sh` — and fails if any file in the correctness loop (`.claude/agents/*.md`,
`gates/verify.sh`, `gates/differential.sh`) so much as references `corpus/features`.
So the cards can be wrong, stale, or deleted and the published accuracy number does
not move. The gate also asserts the cards are byte-identical on re-run and that the
demo's `features-data.js` is a re-emission of the same cards (no hand-paste), and
that every `kind` used maps to a real catalogue entry and skill directory.

## Deferral (pipeline wiring)

Feeding the cards to the analyst as grounding is **deferred behind a measured
miss**, not adopted on faith. If the harness (Phase 4) shows the analyst
*repeatedly* misreading a semantic the extractor detects, the cards become a
candidate input — and even then the precedence is explicit: **golden > skills >
features.json**, with the golden still the sole judge. We do not add coupling to
fix a problem we have not measured.

## Consequences

- **Positive:** the per-proc semantics are legible to a reviewer and in the demo,
  deterministically and for `$0`, without weakening ADR-0001.
- **Positive:** "the parser has no authority" is a mechanical check, not a promise —
  the same discipline ADR-0006 applies to the gate's teeth.
- **Positive:** honest degradation makes the parser's limits visible rather than
  hidden.
- **Cost:** sqlglot is a new (pinned) dependency, but only for regenerating cards
  and demo data — `verify.sh` stays stdlib-only, so the trust chain gains nothing to
  install. Accepted.

## Links

- ADR-0001 — the non-circular gate this tool must not join
- ADR-0006 — the "prove it has teeth" discipline reused to prove this has *none*
- `corpus/extract-features.py` — the extractor
- `gates/features-check.sh` — standalone; proves determinism, sync, taxonomy, and out-of-authority
- `corpus/tests/test_extract_features.py` — unit tests (skip cleanly without sqlglot)
- `docs/superpowers/specs/2026-10-18-ast-grounding-design.md` — the design
