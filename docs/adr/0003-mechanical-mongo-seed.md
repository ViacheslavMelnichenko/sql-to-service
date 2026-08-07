# 0003 — Mechanical Mongo seed: a pure function of the relational seed

- **Status:** Accepted
- **Date:** 2026-08-07
- **Deciders:** Viacheslav Melnichenko

## Context

The differential compares the generated service's output against golden output
captured from the original T-SQL (ADR-0001). But the generated service reads from
**MongoDB**, not SQL Server. So MongoDB needs data. Where does it come from?

This is a trap. If a human (or the model) hand-writes the Mongo documents to make
the service produce the right answer, we have quietly **relocated the oracle
problem**: the golden is no longer independent, because the Mongo data was fitted
to match it. The gate would then be validating that we can hand-fit documents, not
that the model converted correctly.

## Decision drivers

- The Mongo data must be causally derived from the same source as the golden, with
  no hand-fitting.
- The derivation must be fixed and committed *before* any conversion, so it can't
  be adjusted to make a conversion pass.
- It must be inspectable — a reviewer can read it and confirm it's mechanical.

## Considered options

1. **Hand-author Mongo documents per case.** Rejected — relocates the oracle;
   destroys independence.
2. **Let the pipeline generate the Mongo seed as part of conversion.** Rejected —
   same circularity as agent-written tests; the seed would be fitted to the code.
3. **A fixed migration script — pure function of the relational seed — committed
   before any conversion.** Chosen.

## Decision

The Mongo seed is produced by **`corpus/seed/to_mongo.py`**: a deterministic,
committed function that reads the relational seed (ADR-0002) and emits the Mongo
documents by a fixed mapping. It is written **once, before any procedure is
converted**, and it is dumb on purpose — a straightforward relational-to-document
transform, not a model and not tuned per procedure.

Because both sides of the differential now descend from the *same* relational
seed — the golden via the original T-SQL, the Mongo data via a fixed mechanical
migration — neither side is fitted to the other. The comparison stays honest.

## Consequences

- **Positive:** independence of the oracle is preserved end to end; the Mongo side
  is not a place to smuggle in the answer.
- **Positive:** the migration itself is a reviewable artifact — its dumbness is the
  point and is visible.
- **Cost:** the document model is fixed up front, so the pipeline converts *to a
  known target shape* rather than inventing the schema. This is a fair constraint:
  in a real migration the target model is a design decision, not the model's to
  make freely.
- **Cost:** value-based comparison must handle relational→document type
  round-trips (e.g. `decimal` → `Decimal128`) — see the decimal-mapping skill.

## Links

- ADR-0001 — the gate whose independence this protects
- ADR-0002 — the relational seed this is a pure function of
- `corpus/seed/to_mongo.py` — the mechanical migration
- `.claude/skills/decimal-mapping/` — the numeric round-trip rules
