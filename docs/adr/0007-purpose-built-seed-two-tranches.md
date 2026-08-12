# 0007 — A purpose-built seed database, built in two tranches

- **Status:** Accepted
- **Date:** 2026-08-10
- **Deciders:** Viacheslav Melnichenko

## Context

ADR-0002 says the dataset is a small, branch-covering slice; ADR-0003 says the
Mongo seed is a pure function of the *relational seed*. Phase 1 has to turn those
into an actual seed the 14 selected procedures can run against to produce golden.

Reading the 14 verbatim bodies against the live WideWorldImporters (121 MB
restore) surfaced two facts that decide the shape of the seed:

1. **A "narrow window over full WWI" does not work.** The plan of running each
   proc against the full restore under a tight parameter window falls apart on
   `Integration.GetCityUpdates`: WWI carries **37,940 cities**, and every temporal
   window that covers the `2013-01-01` initial load emits ~38k rows. The only
   post-load change points are whole-state/country cascades (hundreds of cities
   each). There is no parameter window that yields a small, readable geography
   golden. `SearchFor*` and the tabular `Get*Updates` slice small; the temporal
   ones do not.

2. **The corpus splits cleanly into two seeding costs.**
   - **11 tractable procs** — the 5 `Website.SearchFor*` plus
     `Integration.GetOrder/GetSale/GetPurchase/GetMovement/GetTransaction/GetStockHoldingUpdates`.
     Plain reads, joins, and decimal arithmetic. This is where the
     `decimal → Decimal128` precision thesis actually lives. A hand-authored
     branch-covering seed is straightforward.
   - **3 temporal procs** — `GetCustomer/GetSupplier/GetCityUpdates`. They read
     **system-versioned history** (`FOR SYSTEM_TIME AS OF @ValidFrom`) driven by
     cursors over `*_Archive` tables, and `GetCity` carries a `geography` column.
     Seeding them means standing up system-versioning, a populated history table,
     geography values, and deep FK chains — a large, fragile job.

## Decision drivers

- Golden must stay small and readable (ADR-0002) **and** a pure function of the
  seed (ADR-0003) — both at once. The window approach cannot, because of GetCity.
- Phase 1 is the trust foundation; it must not stall on temporal-seeding
  yak-shaving before the gate is ever shown to work end to end.
- The corpus decision (`SELECTION.md`) already treats the temporal tier as
  optional weight — four siblings are held back, and the trio is justified as
  "one geography + two temporal representatives," not as load-bearing.

## Considered options

1. **Narrow window over the full 121 MB restore.** Rejected — GetCity emits ~38k
   rows on any initial-load window; golden is neither small nor readable, and the
   seed is not independently inspectable.
2. **Full temporal seed for all 14 up front.** Rejected as the *first* step —
   hand-building system-versioning + `*_Archive` history + geography before any
   golden exists risks Phase 1 stalling before the gate is proven. Kept as
   tranche 2, once there is a green harness to build against.
3. **Trim the corpus to 11.** Rejected — permanently loses the geography and
   temporal-reconstruction showcase, which are the hardest conversions the model
   would face and the most interesting evidence the artifact can offer.
4. **A purpose-built seed database, built in two tranches.** Chosen.

## Decision

The relational seed is a **self-contained, purpose-built database** authored in
`corpus/seed/relational.sql` — not a slice of the full restore. It creates the
base-table schemas, minimal tables carrying **only the columns the selected procs
reference** (at WWI's real types, so the decimal-precision behaviour is
preserved), branch-covering rows, and the selected procedures **verbatim**. The
procs then run against this seed to produce golden. Because the seed is the whole
input and golden is captured by running the originals against it, golden is a pure
function of the seed by construction — the ADR-0003 property holds without a
full-WWI dependency, and Phase 1 no longer needs the 121 MB restore to reproduce
(the restore stays the *source* the rows are drawn from and the place
`select.sql` is re-run).

Build it in **two tranches**:

- **Tranche 1 — the 11 tractable procs.** Seed their 16 tables, capture golden,
  drive the whole gate green end to end (Phases 1 → 3), prove the mutation check
  has teeth (ADR-0006).
- **Tranche 2 — the 3 temporal procs.** Add system-versioned tables, populated
  `*_Archive` history, and geography for `GetCustomer/GetSupplier/GetCityUpdates`,
  against a harness already proven by tranche 1.

The corpus stays **14** (`SELECTION.md` is unchanged); only the *build order* is
tranched.

## Tranche 2 as built

Tranche 2 is complete; both tranches now live in the one `relational.sql`
(the whole input reads top to bottom, per the positive consequence
below). Three implementation decisions were forced by the temporal procs and are
recorded here so they read as design, not accident:

1. **The four shared tables are made system-versioned _in place_, not copied.**
   `Sales.Customers`, `Purchasing.Suppliers`, `Application.People` and
   `Application.Cities` already existed as plain tranche-1 tables, and the temporal
   procs reference the *same two-part names* — there can be only one table per
   name. So tranche 2 adds the extra columns those procs read (as `NULL`able) and
   turns each into a temporal table, rather than standing up parallel copies.
   This does **not** change tranche-1 golden: no tranche-1 proc uses `SELECT *` on
   these tables (verified) — they project explicit columns — so the added columns
   and the (visible) period columns never surface, and no new *current* rows are
   added that would shift a `SearchFor*` match. Confirmed: tranche-1 golden is
   byte-identical before and after.

2. **History is pre-seeded with fixed literals (migrate-existing-data), never
   generated by post-versioning UPDATEs.** The recipe per table is: seed current +
   a plain `*_Archive` history table with fixed-literal `ValidFrom`/`ValidTo`, then
   `ADD PERIOD ... DEFAULT '<fixed literal>'`, then
   `SET SYSTEM_VERSIONING = ON (... DATA_CONSISTENCY_CHECK = ON)`. Turning
   versioning on and *then* issuing UPDATEs would stamp history with the
   transaction's UTC clock — non-deterministic — and break `verify-stable.sh`.
   Period columns are **visible** (not `HIDDEN`): the procs read `c.ValidFrom` /
   `c.ValidTo` as ordinary columns.

3. **`geography` is read as Well-Known-Text; the proc still runs verbatim.**
   `FOR JSON` refuses a CLR type (error 13604), so `capture-golden.py` projects any
   `geography` column through `.STAsText()` (`"POINT (-122.3321 47.6062)"`) — a
   deterministic, diff-able string — when serialising the captured `#temp`. The
   `INSERT..EXEC` still captures the proc's real native output first (ADR-0001
   intact); only the *read* casts to text. Separately, the three temporal procs
   stage output through a `#...Changes` temp table, which defeats
   `sys.dm_exec_describe_first_result_set` (error 11526, "metadata could not be
   determined ... uses a temp table"). So their case files carry an explicit
   `resultset` transcribed verbatim from the proc's own `#...Changes` CREATE TABLE;
   `INSERT..EXEC` is positional and fails loudly on any column-count/type drift, so
   a stale transcription cannot pass silently. (`GetCityUpdates` aliases its
   geography output column to the literal name `geography` in the final SELECT, so
   the golden field is named `geography`, matching the proc's actual output
   contract.)

## Consequences

- **Positive:** Phase 1 is de-risked — a working, inspectable seed and green gate
  exist before the hard temporal seeding is attempted.
- **Positive:** the seed is fully auditable and reproducible without the 121 MB
  restore; `relational.sql` reads top to bottom.
- **Positive:** minimal tables (referenced columns only) keep the seed readable
  and make every column's presence justifiable by a proc that reads it.
- **Cost:** the seed schema is hand-maintained and must stay in sync with the
  proc bodies — a column a proc reads that the seed omits is a compile error at
  capture time (loud, not silent), which is the acceptable failure mode.
- **Cost (retired):** GetCity's geography branch was deferred to tranche 2, so the
  "hardest conversion" evidence landed after the first green gate rather than in
  it. Tranche 2 is now built; the branch is present as WKT (see "Tranche 2 as
  built", point 3).
- **Risk retired by later phases:** that proc-output-on-seed equals
  proc-output-on-full-WWI is *not assumed* — the seed is built as the transitive
  closure of what each case reads, and ADR-0002's mutation check is what proves
  the closure has no holes.

## Links

- ADR-0001 — the non-circular gate this seed feeds
- ADR-0002 — branch-coverage sizing; the mutation check that validates it
- ADR-0003 — the mechanical Mongo seed this relational seed is the source for
- ADR-0006 — mutation validation that proves the seed has no branch holes
- `corpus/SELECTION.md` — the 14-proc corpus (unchanged; only build order tranches)
- `corpus/seed/relational.sql` — the purpose-built seed (both tranches)
