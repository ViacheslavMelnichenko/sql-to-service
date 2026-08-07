# 0001 — Non-circular gate: capture golden before any model runs

- **Status:** Accepted
- **Date:** 2026-08-07
- **Deciders:** Viacheslav Melnichenko

## Context

The whole artifact rests on one claim: that we can *trust* an unreliable model's
output on a migration task. Trust needs an oracle — something that decides
"correct" independently of the thing being judged. The obvious failure mode, and
the one nearly every "the AI tested its own work" demo falls into, is
**circularity**: the model writes both the code and the tests, so the tests encode
the same misunderstanding as the code. Both agree; both are wrong. A green suite
proves nothing.

## Decision drivers

- The oracle must be causally independent of the model.
- A reviewer must be able to see *why* it is independent, not take it on faith.
- The comparison must be mechanical and reproducible without model calls.

## Considered options

1. **Agent-written unit tests as the gate.** Rejected — circular by construction.
2. **A second model reviews the first model's output.** Rejected — reduces but
   does not remove correlation; two models share training-distribution blind
   spots, and it costs model calls to reproduce.
3. **Golden output captured from the original procedure before any model runs,
   compared value-by-value against the generated service's output.** Chosen.

## Decision

The correctness oracle is the **golden output**: we run each original T-SQL
procedure against the seeded database and capture its result set as canonical JSON
**before any model has seen the problem**. The gate that decides "this conversion
is correct" is the **differential** — the generated service's output compared,
value by value, against that golden JSON.

Agent-written unit tests still exist and still run (`gates/unit.sh`), but they
**never pass the gate on their own**. They are a fast local signal for the agent;
only the differential has authority.

The golden is frozen in git before the pipeline runs. There is no code path by
which the model can influence it.

## Consequences

- **Positive:** the oracle is a fact about the original system, not an opinion the
  model helped form. Reproducible with zero model calls (`gates/verify.sh`).
- **Positive:** makes the trust claim *falsifiable* — see ADR-0006, which requires
  proving the gate actually fails on a wrong conversion.
- **Cost:** only read-only, deterministic, single-result-set procedures can have a
  stable golden — this constrains the corpus (see `corpus/SELECTION.md`).
- **Cost:** the MongoDB side of the comparison needs data that is *not*
  hand-fitted, or we relocate the oracle problem — addressed by ADR-0003.

## Links

- `corpus/SELECTION.md` — the read-only/deterministic constraint this forces
- ADR-0003 — mechanical Mongo seed (closes the relocated-oracle gap)
- ADR-0006 — mutation validation (proves the gate has teeth)
