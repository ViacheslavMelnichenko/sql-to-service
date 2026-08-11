# Spec: `Integration.GetTransactionUpdates`

*Written by the `analyst` stage from `corpus/procs/Integration.GetTransactionUpdates.sql`,
`corpus/cases/Integration.GetTransactionUpdates.json`, and the four goldens
(`__jan-both-arms`, `__feb-coalesce-fallback`, `__both-months`, `__empty-window`).
Intent, not translation.*

## Purpose
The caller gets an incremental change-feed of financial transactions edited within
a time window — customer transactions and supplier transactions merged into **one**
flat result with a shared 17-column contract. It is the classic "give me everything
that changed since last time" integration pull.

## Parameters
Both `datetime2(7)`, both filters (a time window; neither is a row limit):

- `@LastCutoff` — exclusive lower bound. Rows with `LastEditedWhen` **strictly
  greater than** this are eligible.
- `@NewCutoff` — inclusive upper bound. Rows with `LastEditedWhen` **less than or
  equal to** this are eligible.

Together they define the **half-open window `(@LastCutoff, @NewCutoff]`** — open at
the bottom, closed at the top. This same window is applied independently to each
arm's `LastEditedWhen`. There is no row limit.

## Data read
The result is a `UNION ALL` of two arms. `UNION ALL` means **no dedup** — every row
from both arms passes through, even if two rows were byte-identical (they can't be
here, but the port must not silently distinct them).

**Arm 1 — Customer transactions.**
- `Sales_CustomerTransactions` (SQL alias `ct`). Per KEY_MAP, its primary key
  `CustomerTransactionID` is the Mongo `_id`; the value surfaced as
  `WWI Customer Transaction ID` comes from `_id`, not a literally-named column. The
  join key `ct.InvoiceID` is a plain field on the doc.
- `LEFT OUTER JOIN Sales_Invoices` (alias `i`) `ON ct.InvoiceID = i.InvoiceID`.
  `Sales_Invoices._id` is `InvoiceID` (KEY_MAP), so the join is
  `ct.InvoiceID == i._id`. LEFT means: a customer transaction is **always kept**
  even when its `InvoiceID` is NULL or matches no invoice — the invoice side simply
  contributes nothing.

**Arm 2 — Supplier transactions.**
- `Purchasing_SupplierTransactions` (alias `st`), **no join**. Its key
  `SupplierTransactionID` is `_id`; `WWI Supplier Transaction ID` comes from `_id`.

## Filtering
Each arm has the identical `WHERE`:

```
LastEditedWhen > @LastCutoff  AND  LastEditedWhen <= @NewCutoff
```

Behavioural traps:

- **Half-open boundary.** A row edited exactly at `@LastCutoff` is **excluded**
  (strict `>`); a row edited exactly at `@NewCutoff` is **included** (`<=`). This is
  what makes consecutive windows tile without gaps or overlaps. Get the operators
  backwards and you double-count or drop boundary rows.
- The filter is on `LastEditedWhen`, **not** on `TransactionDate`. In the seed both
  transactions share `LastEditedWhen = 2020-01-20T09:00:00` (customer #1, supplier
  #1) and `2020-02-20T09:00:00` (customer #2) — note these are datetimes with a time
  component, while `TransactionDate` is a different, earlier date.
- No case-sensitivity / `LIKE` / `CONCAT` concerns here; the only filter is the
  temporal window.

## The COALESCE fallback (Customer arm — the central trap)
`[WWI Customer ID]` is `COALESCE(i.CustomerID, ct.CustomerID)`:

- **When the invoice join hits** (ct.InvoiceID matches an invoice), take the
  **invoice's** `CustomerID`. Case `jan-both-arms`: CT 1 has `InvoiceID = 1`, invoice
  1 has `CustomerID = 1`, so `WWI Customer ID = 1`.
- **When there is no invoice** (`ct.InvoiceID` is NULL → LEFT join produces no
  match → `i.CustomerID` is NULL), **fall back to `ct.CustomerID`**. Case
  `feb-coalesce-fallback`: CT 2 has `InvoiceID = NULL`, `ct.CustomerID = 2`, so
  `WWI Customer ID = 2`.

`[WWI Bill To Customer ID]` is always `ct.CustomerID` (NOT the invoice's
`BillToCustomerID` — do not be tempted). So in the seed both `WWI Customer ID` and
`WWI Bill To Customer ID` happen to equal `ct.CustomerID` in every case, but they
are computed differently: only `WWI Customer ID` can be pulled from the invoice.
An implementer who copies one into the other will pass these goldens by luck and
break on any data where `i.CustomerID != ct.CustomerID`.

## Ordering & limiting
**There is no `ORDER BY` and no `TOP`/limit.** The case sets `ordered: false`:
**row order is not part of the contract.** The canonicaliser sorts rows by value
before comparing, so the port may emit rows in any order (e.g. all customer rows
then all supplier rows, or interleaved) and still match. Do **not** invent an
`ORDER BY` to "stabilise" output — none is required, and none is asserted.

## Output shape (`tabular`)
A flat JSON array of objects, one per row, no root wrapper, no nesting. **Both arms
project the SAME 17 columns in the same positions**; each arm hard-codes
`CAST(NULL AS ...)` for the columns that don't apply to it, and the golden **always
emits all 17 keys** — the inapplicable ones as JSON `null` (keys are never omitted).

Golden key order is **alphabetical** (the tabular capture serialises sorted keys —
reproduce this order):

| Golden key (order) | Source (customer arm) | Source (supplier arm) | Type in output |
|--------------------|-----------------------|-----------------------|----------------|
| `Date Key` | `CAST(ct.TransactionDate AS date)` | `CAST(st.TransactionDate AS date)` | date-only string `"YYYY-MM-DD"` |
| `Is Finalized` | `ct.IsFinalized` | `st.IsFinalized` | bool (unquoted `true`/`false`) |
| `Last Modified When` | `ct.LastEditedWhen` | `st.LastEditedWhen` | datetime string |
| `Outstanding Balance` | `ct.OutstandingBalance` | `st.OutstandingBalance` | **decimal as JSON string** |
| `Supplier Invoice Number` | **NULL** | `st.SupplierInvoiceNumber` | string / null |
| `Tax Amount` | `ct.TaxAmount` | `st.TaxAmount` | **decimal as JSON string** |
| `Total Excluding Tax` | `ct.AmountExcludingTax` | `st.AmountExcludingTax` | **decimal as JSON string** |
| `Total Including Tax` | `ct.TransactionAmount` | `st.TransactionAmount` | **decimal as JSON string** |
| `WWI Bill To Customer ID` | `ct.CustomerID` | **NULL** | int / null |
| `WWI Customer ID` | `COALESCE(i.CustomerID, ct.CustomerID)` | **NULL** | int / null |
| `WWI Customer Transaction ID` | `ct._id` | **NULL** | int / null |
| `WWI Invoice ID` | `ct.InvoiceID` | **NULL** | int / null |
| `WWI Payment Method ID` | `ct.PaymentMethodID` | `st.PaymentMethodID` | int / null |
| `WWI Purchase Order ID` | **NULL** | `st.PurchaseOrderID` | int / null |
| `WWI Supplier ID` | **NULL** | `st.SupplierID` | int / null |
| `WWI Supplier Transaction ID` | **NULL** | `st._id` | int / null |
| `WWI Transaction Type ID` | `ct.TransactionTypeID` | `st.TransactionTypeID` | int |

**Which columns are NULL in which arm (the trap — verify both directions):**

- **Customer arm hard-NULLs:** `WWI Supplier Transaction ID`, `WWI Purchase Order ID`,
  `Supplier Invoice Number`, `WWI Supplier ID`.
- **Supplier arm hard-NULLs:** `WWI Customer Transaction ID`, `WWI Invoice ID`,
  `WWI Customer ID`, `WWI Bill To Customer ID`.

`WWI Payment Method ID` is projected by **both** arms (it is genuinely null for a row
only when the underlying `PaymentMethodID` is null, e.g. customer #1 and supplier #1,
which is *data-driven* null, not a hard-coded arm NULL — see `jan-both-arms`).

`Date Key` must be **date-only** — `"2020-01-05"`, no time component — even though the
source `TransactionDate` and `LastModifiedWhen` carry different values. Confirm you
project `TransactionDate` here, not `LastEditedWhen`.

A golden customer row (from `jan-both-arms`):

```json
{"Date Key":"2020-01-05","Is Finalized":true,"Last Modified When":"2020-01-20T09:00:00",
 "Outstanding Balance":"0.0000","Supplier Invoice Number":null,"Tax Amount":"37.5000",
 "Total Excluding Tax":"250.0000","Total Including Tax":"287.5000","WWI Bill To Customer ID":1,
 "WWI Customer ID":1,"WWI Customer Transaction ID":1,"WWI Invoice ID":1,
 "WWI Payment Method ID":null,"WWI Purchase Order ID":null,"WWI Supplier ID":null,
 "WWI Supplier Transaction ID":null,"WWI Transaction Type ID":1}
```

## Per-case expectations
- **`jan-both-arms`** — window `(2020-01-01, 2020-02-01]`. Returns **2 rows**: CT 1
  (customer arm; join hits invoice 1, so `WWI Customer ID = 1` from the invoice side)
  and ST 1 (supplier arm; carries `Supplier Invoice Number = "SI-001"`,
  `WWI Supplier ID = 1`, `WWI Purchase Order ID = 1`). Both edited 2020-01-20, inside
  the window. Exercises the UNION ALL emitting both arms and the COALESCE i-side.
- **`feb-coalesce-fallback`** — window `(2020-02-01, 2020-03-01]`. Returns **1 row**:
  CT 2 only. `InvoiceID` is NULL → COALESCE falls back to `ct.CustomerID = 2`. No
  supplier row edited in Feb. `Is Finalized` is `false` here (the only non-finalized
  row), `WWI Payment Method ID = 4`, `Outstanding Balance = "110.0000"`. Exercises the
  COALESCE fallback branch.
- **`both-months`** — window `(2020-01-01, 2020-03-01]`. Returns **3 rows**: CT 1,
  ST 1, and CT 2 — both COALESCE branches plus the supplier arm together. (Order is
  not asserted; canonicaliser sorts.)
- **`empty-window`** — window `(2019-01-01, 2019-02-01]`, entirely before any edit.
  Returns **`[]`** — both arms yield nothing. The port must emit an empty array, not
  null or an error.

## Precision-sensitive fields
Four `decimal` money columns, present in **both** arms and never hard-NULLed:

- `Total Excluding Tax` (`AmountExcludingTax`)
- `Tax Amount` (`TaxAmount`)
- `Total Including Tax` (`TransactionAmount`)
- `Outstanding Balance` (`OutstandingBalance`)

All four are stored in the seed as Decimal128 (`{"$numberDecimal":"..."}`, never a
float) and must surface as **quoted JSON strings at fixed scale 4** — e.g.
`"250.0000"`, `"37.5000"`, `"287.5000"`, `"0.0000"`, `"110.0000"` — exactly as the
goldens show. They must **not** be emitted as unquoted numbers, and must **not** be
routed through a `float`/`double` at any point (that would drop trailing zeros and
risk precision loss). Treat as a Decimal128 → fixed-scale-4 string passthrough, per
the decimal-mapping skill and the pattern in `generated/GetStockHoldingUpdatesService.cs`.

Non-decimal numerics — `WWI Transaction Type ID`, `WWI Payment Method ID`, all the
ID columns — are plain integers (unquoted JSON numbers, or `null`). `Is Finalized`
is an unquoted JSON `bool`.

## Open risks for the implementer
- **Decimal-string vs. number (highest risk).** All four money columns must be
  quoted, fixed-scale-4 strings read straight from Decimal128. The default temptation
  (deserialise to `decimal`/`double` and let the serialiser render a number) fails the
  golden on both quoting and trailing-zero scale.
- **COALESCE direction and Bill-To distinction.** `WWI Customer ID` prefers the
  **invoice's** `CustomerID`, falling back to `ct.CustomerID` only when there's no
  invoice; `WWI Bill To Customer ID` is **always** `ct.CustomerID`. They coincide in
  this seed but are not the same expression — implement both, don't alias one to the
  other.
- **Per-arm hard NULLs.** Each arm zeroes out four specific columns (listed above).
  All 17 keys must appear in every row with JSON `null` for the inapplicable ones;
  never omit a key.
- **Window operators.** `>` at the low end, `<=` at the high end — a row exactly on
  `@LastCutoff` is out, a row exactly on `@NewCutoff` is in. Filter on
  `LastEditedWhen`, not `TransactionDate`.
- **`Date Key` is date-only.** Project `TransactionDate` cast to date (`"2020-01-05"`),
  distinct from the datetime `Last Modified When`.
- **No ORDER BY (`ordered: false`).** Do not add sorting to stabilise output; row
  order is not contractual and the canonicaliser sorts before comparing. Empty window
  must return `[]`.
- **IDs from `_id`.** `WWI Customer Transaction ID` and `WWI Supplier Transaction ID`
  come from each collection's `_id`; the invoice join is `ct.InvoiceID == i._id`. Don't
  look for literally-named `CustomerTransactionID` / `SupplierTransactionID` /
  `InvoiceID` fields on the joined doc's identity.
- **UNION ALL, not UNION.** Do not dedup rows across arms.
