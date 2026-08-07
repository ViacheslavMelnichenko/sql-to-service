# Procedure selection

The corpus is not "whatever procedures exist" — it is a **deliberately chosen,
falsifiable set**. The criterion is written here *before* the outcome is known, so
a reviewer can check we didn't cherry-pick the procedures that happened to convert
well. Every candidate that meets the criterion is either in, or excluded with a
one-line reason.

## Criterion (applied before any conversion)

A procedure is **in** the corpus if and only if all of these hold:

1. **Read-only.** No `INSERT` / `UPDATE` / `DELETE` / `MERGE`. A read path has a
   golden output that is a pure function of the seed; a write path would need
   state rollback between cases and muddies the differential.
2. **Single result set.** One `SELECT` shape out, so the golden JSON is one array
   of rows — comparable value-by-value.
3. **Deterministic.** No `NEWID()`, `GETDATE()`/`SYSDATETIME()` in the output, no
   dependence on server state. Same inputs → same output, or it cannot have a
   stable golden.
4. **≤ 5 parameters.** Keeps the param-case matrix (§0.3) small enough to be
   branch-covering without exploding.
5. **Non-trivial body.** At least a join or a `CASE` or an optional filter — a
   plain single-table lookup proves nothing about the pipeline. (We want at least
   a few `SearchFor*` with real relevance/ordering logic — the showcase pool.)

## Candidate schemas

Two schemas in WideWorldImporters expose procedures that fit the read-only,
single-result-set shape:

- **`Website`** — `Website.SearchFor*` (customers, suppliers, stock items): real
  joins, `CASE`, relevance ordering, optional filters. The strongest showcase
  material.
- **`Integration`** — `Integration.Get*Updates` (movements, sales, purchases,
  transactions, etc.): parameterized read extracts, single result set.

Between them the source exposes on the order of **17–18** procedures that pass a
first read-only/single-result-set screen; the full enumeration is produced
mechanically by `corpus/select.sql` (task 0.2 / Phase 1) and pasted below when it
runs.

## Target size

- **Band: 12–20 procedures. Hard cap: 20.**
- Below 12, the per-proc distribution is too small to say anything honest.
- Above 20, the seed and golden capture grow past what a size-S artifact should
  carry, and the marginal procedure adds no new branch class.
- Within the band we prefer **coverage of distinct branch shapes** over raw count:
  a 13th `Get*Updates` that looks like the 12th earns its place less than a
  `SearchFor*` with a new ordering rule.

## Enumeration + inclusion table

*(Filled by `corpus/select.sql` in Phase 1. Until then this is the shape.)*

| Procedure | Schema | Params | Read-only | Single result | Deterministic | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| `Website.SearchForCustomers` | Website | … | ✓ | ✓ | ✓ | *pending run* |
| … | … | … | … | … | … | … |

## Exclusions (recorded, not hidden)

A procedure that meets the read-only screen but is left out gets a line here, so
an absence never reads as an oversight:

| Procedure | Why excluded |
| --- | --- |
| *(e.g. a proc emitting multiple result sets)* | violates criterion 2 |
| *(e.g. a proc using `SYSDATETIME()` in output)* | violates criterion 3 |

## Introduced specifics (overrule cheaply)

- **~17–18 candidates** is an estimate from the schema shape, not a counted
  figure — `select.sql` replaces it with the real count.
- The **12–20 band / cap 20** is a sizing choice tied to the S budget, not a
  property of the corpus.
- Preferring branch-shape coverage over count is a stated selection policy; it is
  what a reviewer would otherwise suspect us of *not* doing.
