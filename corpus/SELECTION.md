# Procedure selection

The corpus is not "whatever procedures exist" — it is a **deliberately chosen,
falsifiable set**. The criterion is written here *before* the outcome is known, so
a reviewer can check we didn't cherry-pick the procedures that happened to convert
well. Every candidate that meets the criterion is either in, or excluded with a
one-line reason.

## Criterion (applied before any conversion)

A procedure is **in** the corpus if and only if all of these hold:

1. **No persistent state change.** No `INSERT` / `UPDATE` / `DELETE` / `MERGE`
   against a *base table*. The rationale is what matters: the golden must be a
   pure function of seed + params, with no state to roll back between cases. A
   procedure that writes only to a `#temp` table (dropped at proc exit) and then
   `SELECT`s from it satisfies this — nothing persists, so re-running a case can't
   see a prior case's effect. This distinction is load-bearing here: a naive
   "contains the word INSERT" screen flags all thirteen `Integration.Get*Updates`,
   but seven of them only populate a `#temp` result set via cursor + temporal
   history and change no base table. They are **in**. (See the enumeration note.)
2. **Single result set.** One `SELECT` shape out, so the golden JSON is one array
   of rows — comparable value-by-value. Two output *shapes* occur in the corpus and
   the capture handles both: the 5 `SearchFor*` end in `FOR JSON` (SQL Server
   returns one JSON string, chunked across rows at 2033 chars — the capture
   concatenates then parses); the 9 `Get*Updates` return a tabular row set (the
   capture wraps it to JSON via `sp_describe_first_result_set` + `INSERT…EXEC`).
   Either way the golden is one canonical JSON array.
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

The full enumeration is produced mechanically by `corpus/select.sql` and pasted
below. The screen uses SQL Server's own dependency engine
(`sys.dm_sql_referenced_entities`, `is_updated`) to decide criterion 1 — not a
substring scan of the body, which cannot tell a `#temp` write from a base-table
write and misreads aliases. Run against the restored database, it reports **18**
procedures with **no base-table write** and no non-determinism, and **6** that
write a base table (excluded). All 24 have ≤ 5 parameters.

## Target size

- **Band: 12–20 procedures. Hard cap: 20.**
- Below 12, the per-proc distribution is too small to say anything honest.
- Above 20, the seed and golden capture grow past what a size-S artifact should
  carry, and the marginal procedure adds no new branch class.
- Within the band we prefer **coverage of distinct branch shapes** over raw count:
  a 13th `Get*Updates` that looks like the 12th earns its place less than a
  `SearchFor*` with a new ordering rule.

## Enumeration + inclusion table

Produced by `corpus/select.sql` against the restored WWI (2026-08-08). `no base
write` and `det` are the mechanical screen; `IN`/`hold` is the branch-diversity
selection on top of it (§Target size). "shape" summarises what makes the row
distinct.

| Procedure | Params | No base write | Det | Shape | Verdict |
| --- | --- | --- | --- | --- | --- |
| `Website.SearchForCustomers` | 2 | ✓ | ✓ | relevance search, optional filter | **IN** |
| `Website.SearchForSuppliers` | 2 | ✓ | ✓ | relevance search | **IN** |
| `Website.SearchForStockItems` | 2 | ✓ | ✓ | relevance search, smallest body | **IN** |
| `Website.SearchForStockItemsByTags` | 2 | ✓ | ✓ | tag search — different match path | **IN** |
| `Website.SearchForPeople` | 2 | ✓ | ✓ | relevance search, permission filter | **IN** |
| `Integration.GetOrderUpdates` | 2 | ✓ | ✓ | simple join extract | **IN** |
| `Integration.GetSaleUpdates` | 2 | ✓ | ✓ | join extract, wider projection | **IN** |
| `Integration.GetPurchaseUpdates` | 2 | ✓ | ✓ | join extract | **IN** |
| `Integration.GetMovementUpdates` | 2 | ✓ | ✓ | smallest join extract | **IN** |
| `Integration.GetTransactionUpdates` | 2 | ✓ | ✓ | multi-join extract | **IN** |
| `Integration.GetStockHoldingUpdates` | 0 | ✓ | ✓ | zero-param extract (edge case) | **IN** |
| `Integration.GetCityUpdates` | 2 | ✓ | ✓ | cursor + temporal + **geography** | **IN** |
| `Integration.GetCustomerUpdates` | 2 | ✓ | ✓ | cursor + temporal, richest body | **IN** |
| `Integration.GetSupplierUpdates` | 2 | ✓ | ✓ | cursor + temporal, 2nd variant | **IN** |
| `Integration.GetEmployeeUpdates` | 2 | ✓ | ✓ | cursor + temporal | hold |
| `Integration.GetStockItemUpdates` | 2 | ✓ | ✓ | cursor + temporal | hold |
| `Integration.GetPaymentMethodUpdates` | 2 | ✓ | ✓ | cursor + temporal | hold |
| `Integration.GetTransactionTypeUpdates` | 2 | ✓ | ✓ | cursor + temporal | hold |

**Corpus = the 14 marked `IN`.** All 18 pass the mechanical screen; the four
`hold` are cursor-plus-temporal siblings of `GetCustomerUpdates`/`GetSupplierUpdates`
and add no new branch shape, so per the size policy they are held back rather than
padding the count. They stay one line away from inclusion if a run shows the
complex tier needs more weight.

## Exclusions (recorded, not hidden)

The six procedures the mechanical screen rejects — each writes a base table
(`is_updated = 1`), violating criterion 1:

| Procedure | Params | Why excluded |
| --- | --- | --- |
| `Website.InsertCustomerOrders` | 4 | writes base tables; also non-deterministic output |
| `Website.InvoiceCustomerOrders` | 3 | writes base tables; also non-deterministic output |
| `Website.ActivateWebsiteLogon` | 3 | writes a base table (updates logon state) |
| `Website.ChangePassword` | 3 | writes a base table (updates credential) |
| `Website.RecordColdRoomTemperatures` | 1 | writes a base table (sensor insert) |
| `Website.RecordVehicleTemperature` | 1 | writes a base table (sensor insert) |

**Note on the `Get*Updates` write-screen.** A naive "body contains INSERT/UPDATE"
scan flags all thirteen `Get*Updates` — they populate a `#temp` result table via
cursor and `UPDATE <alias> ... FROM #temp`. The dependency-engine screen correctly
reports `writes_base_table = 0` for every one: the writes hit `#temp`, never a base
table, so criterion 1 admits them. This is exactly the false positive the coarse
scan would have produced, avoided.

## Introduced specifics (overrule cheaply)

- **18 candidates pass, corpus = 14** — these are counted from `select.sql`, not
  estimated. The choice to include 14 of the 18 (holding back four look-alike
  complex `Get*Updates`) is the branch-diversity policy applied; overrule by moving
  a `hold` row to `IN`.
- The specific 3 complex procs chosen (`GetCity` for geography, `GetCustomer` and
  `GetSupplier` as the cursor+temporal representatives) is a judgement call to get
  one geography branch and two temporal-reconstruction branches without carrying
  all seven. A reviewer who wants the full complex tier flips the four `hold` rows.
- The **12–20 band / cap 20** is a sizing choice tied to the S budget, not a
  property of the corpus.
- Criterion 1 was refined during Phase 1 from "no INSERT/UPDATE/DELETE/MERGE" to
  "no *base-table* write," because the literal reading would have wrongly excluded
  the entire `Get*Updates` family over their `#temp` scratch tables. The rationale
  (no state to roll back between cases) is unchanged; the wording now matches it.
