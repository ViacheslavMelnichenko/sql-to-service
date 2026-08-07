# 0002 — Dataset sizing: branch coverage, not volume

- **Status:** Accepted
- **Date:** 2026-08-07
- **Deciders:** Viacheslav Melnichenko

## Context

The golden output is only as good as the data behind it. If a correct conversion
and an incorrect one produce the *same* JSON on our seed, the gate is blind — the
golden can't discriminate. So the question "how much test data?" is really "how
much data does the gate need to catch a wrong conversion?" That is a question
about **discrimination**, not realism or volume. WideWorldImporters ships with
millions of rows; we need a small, deterministic slice that makes every branch of
every procedure produce a *distinguishable* result.

## Decision drivers

- The seed must make each branch of each procedure observable in the output.
- It must stay small enough that golden JSON is readable and capture is
  deterministic.
- The sizing must be *derived from the procedures*, not assigned up front.

## Considered options

1. **A large realistic sample (thousands of rows).** Rejected — golden becomes
   unreadable, capture slower, and volume doesn't imply branch coverage.
2. **A fixed arbitrary number of rows per table.** Rejected — either misses a
   branch or wastes rows; not derived from the code.
3. **Branch-covering minimal seed, sized per procedure.** Chosen.

## Decision

Size the dataset **from the procedures, by branch coverage**:

1. For each selected procedure, enumerate its branches — `WHERE` clauses, `CASE`
   arms, optional filters, ordering/relevance rules, pagination bounds.
2. Choose the minimal set of **param-cases** (5–8 per procedure) that exercises
   each branch: empty result, single match, multiple matches (tests ordering),
   NULL optional parameter, a pagination boundary, plus 1–2 procedure-specific
   cases.
3. Build the relational seed so those cases produce **distinct, non-empty,
   distinguishable** outputs.

Working targets (derived, not decreed): **~50–200 rows per key table**, **5–8
param-cases per procedure**, **~80–160 golden records** total across the corpus.

The proof that the sizing is sufficient is **ADR-0006's mutation check**: if an
injected bug in a branch is *not* caught, the seed has a hole in that branch and a
row is added until it is.

## Consequences

- **Positive:** every committed row earns its place by making some branch
  observable; nothing is decorative.
- **Positive:** golden stays small, readable, and deterministic.
- **Positive:** ties directly to gate validation — dataset holes surface as
  uncaught mutants, not as silent gaps.
- **Cost:** requires per-procedure branch analysis up front (the `analyst`
  subagent's spec output helps here).

## Links

- ADR-0001 — the gate this data has to feed
- ADR-0006 — mutation check that validates the sizing is sufficient
- `corpus/cases/*.json` — the param-case sets
- `corpus/seed/relational.sql` — the branch-covering seed
