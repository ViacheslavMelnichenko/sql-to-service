# 0006 — Mutation validation: prove the gate has teeth

- **Status:** Accepted
- **Date:** 2026-08-07
- **Deciders:** Viacheslav Melnichenko

## Context

ADR-0001 gives us a non-circular gate. But a gate that has never been shown to
*fail* on a wrong conversion is an untested gate — its green is worth nothing. Two
things could make it silently toothless: the differential comparison might be too
loose (ignoring a field, tolerating an ordering difference), or the seed might not
discriminate a branch (ADR-0002), so a real bug produces the same golden anyway.
Either way the gate passes bad code and we'd never know.

## Decision drivers

- The gate's authority must be demonstrated, not asserted.
- The demonstration must be reproducible and committed, not a one-off manual check.
- A failure to catch a bug must point at *what* to fix (comparison vs seed).

## Considered options

1. **Trust the gate because the design is sound.** Rejected — "should catch" is not
   "was shown to catch." This is the exact assertion the artifact refuses to make
   about the AI; it can't make it about its own gate.
2. **Rely on the natural failures the pipeline produces.** Rejected — those are
   uncontrolled; they don't prove coverage of a *specific* branch, and a clean run
   would leave the gate unvalidated.
3. **Deliberate mutation testing of the gate.** Chosen — and **mandatory**.

## Decision

**`gates/mutation-check.sh` is a required, non-optional gate-validation step**
(task 3.9; blocks Phase-3 exit). It takes a known-correct conversion, injects a
catalogue of **known bugs**, and asserts the gate catches **every one**:

- drop a `WHERE` clause (returns too many rows),
- break an `ORDER BY` / relevance rule (right rows, wrong order),
- shift a pagination bound (off-by-one window),
- swap or drop a join (wrong or missing columns),
- coerce a numeric type wrongly (`decimal` precision loss).

Each mutant the gate **fails to catch** is triaged: if the differential ignored the
difference, the comparison is tightened; if the golden was identical for mutant and
original, the seed has a **branch hole** (ADR-0002) and a row is added until the
mutant is distinguishable. **A single uncaught mutant blocks Phase-3 exit.**

## Consequences

- **Positive:** turns "we have tests" into "we proved the tests have teeth" — the
  single strongest credibility artifact against the "too perfect / curated" and
  "the gate is circular" dismissals.
- **Positive:** couples gate quality and dataset sufficiency into one check — a
  seed hole can't hide.
- **Positive:** the mutation catalogue is itself a committed, reviewable artifact.
- **Cost:** authoring and maintaining the mutation set; every new branch class
  should gain a corresponding mutant. Accepted — it's the cost of a gate you can
  defend under three follow-up questions.

## Links

- ADR-0001 — the gate being validated
- ADR-0002 — dataset sizing; uncaught mutants reveal its holes
- `gates/mutation-check.sh` — the mandatory check
- `docs/tasks/README.md` §3.9 — mandatory, blocks phase exit
