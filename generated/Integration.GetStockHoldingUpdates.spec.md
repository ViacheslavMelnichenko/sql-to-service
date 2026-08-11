# Spec: `Integration.GetStockHoldingUpdates`

*Written by the `analyst` stage from `corpus/procs/Integration.GetStockHoldingUpdates.sql`,
`corpus/cases/Integration.GetStockHoldingUpdates.json`, and the single
`corpus/golden/Integration.GetStockHoldingUpdates__all-holdings.json`. Intent, not translation.*

## Purpose
The caller gets a flat dump of the entire stock-holdings table — one row per stock
item, carrying its on-hand quantity, bin location, stocktake figures, cost price,
and reorder thresholds — sorted by stock item id. It is a parameterless "give me
everything" export intended for downstream integration.

## Parameters
None. The proc takes zero parameters, so a single invocation fully covers it.

## Data read
One collection only, no joins:

- `Warehouse_StockItemHoldings` (SQL alias `sih`). One document per stock item.
  Every column in the table is projected; nothing is filtered out.

Per the KEY_MAP, the SQL primary key `StockItemID` is stored as the Mongo document
`_id`. So the field surfaced as `WWI Stock Item ID` — and the sort key — comes from
`_id`, **not** from a field literally named `StockItemID`. All other columns
(`QuantityOnHand`, `BinLocation`, `LastStocktakeQuantity`, `LastCostPrice`,
`ReorderLevel`, `TargetStockLevel`) keep their names verbatim in the seed.

## Filtering
None. There is no `WHERE` clause. Every document in
`Warehouse_StockItemHoldings` is returned. In the seed that is exactly two rows.

## Ordering & limiting
`ORDER BY sih.StockItemID` ascending — which, after the KEY_MAP rename, means
**order by `_id` ascending**. There is no `TOP` / row limit; the whole table comes
back. The golden shows the two rows in id order: `_id` 1 first, then `_id` 2.

The case sets `ordered: true`: row order is part of the contract. The output array
must be `[item 1, item 2]` in that sequence and must not be re-sorted or
canonicalised away.

## Output shape (`tabular`)
A flat JSON array of objects, one per row. **Each output key is the friendly `AS`
alias — with spaces — exactly as it appears in the golden**, not the source column
name. The golden emits keys in this order (alphabetical, which is how the capture
serialised the tabular row — reproduce this exact order):

| Golden key (order) | Source column | Type in output |
|--------------------|---------------|----------------|
| `Bin Location` | `BinLocation` | string |
| `Last Cost Price` | `LastCostPrice` | **decimal as JSON string** — see below |
| `Last Stocktake Quantity` | `LastStocktakeQuantity` | integer (JSON number) |
| `Quantity On Hand` | `QuantityOnHand` | integer (JSON number) |
| `Reorder Level` | `ReorderLevel` | integer (JSON number) |
| `Target Stock Level` | `TargetStockLevel` | integer (JSON number) |
| `WWI Stock Item ID` | `StockItemID` (= Mongo `_id`) | integer (JSON number) |

A golden row looks like:

```json
{"Bin Location":"L-1","Last Cost Price":"12.5000","Last Stocktake Quantity":95,
 "Quantity On Hand":100,"Reorder Level":20,"Target Stock Level":200,
 "WWI Stock Item ID":1}
```

Shape rules the port must reproduce exactly:

- Keys carry the spaces (`Quantity On Hand`, not `QuantityOnHand`).
- No nesting, no root wrapper — a plain array of flat objects.
- All fields are present and non-null for both seed rows; there is no null-omission
  case to worry about here.

## Precision-sensitive fields
- **`Last Cost Price`** (from `LastCostPrice`, `decimal(18,2)` in SQL; stored in the
  seed as a Decimal128, `{"$numberDecimal":"12.5000"}`, **never** a float/double).

  This is the one trap in the proc. In the golden the value is a **quoted JSON
  string at fixed scale 4**: `"Last Cost Price":"12.5000"` for row 1 and `"8.0000"`
  for row 2 — note the trailing zeros and the quotes. The service must surface this
  value as the exact fixed-scale decimal **string**:
  - It must **not** emit a JSON number (`12.5` or `12.50` or `12.5000` unquoted).
  - It must **not** route the value through a `float`/`double` at any point — that
    would drop the trailing zeros and risk precision loss.
  - It must round-trip `Decimal128 → "12.5000"` preserving scale exactly, per the
    decimal-mapping rules.

  Every other numeric field (`Quantity On Hand`, `Last Stocktake Quantity`,
  `Reorder Level`, `Target Stock Level`, `WWI Stock Item ID`) is a plain integer and
  is emitted as an unquoted JSON number.

## Open risks for the implementer
- **Decimal-string vs. number (highest risk).** `Last Cost Price` must come out as
  the quoted, fixed-scale-4 string `"12.5000"` / `"8.0000"`, read straight from the
  Decimal128 seed value. The default temptation — deserialising to `decimal`/`double`
  and letting the JSON serialiser render a number — will fail the golden on both the
  quoting and the trailing-zero scale. Treat it as a Decimal128-to-string passthrough
  that preserves scale.
- **Order by `_id`.** The ORDER BY key `StockItemID` is the Mongo `_id` after the
  KEY_MAP rename; sort on `_id` ascending. `ordered: true`, so the emitted order
  (1 then 2) is contractual.
- **Alias keys with spaces.** Output keys are the friendly aliases, not the source
  column names, and their order in the golden is alphabetical — match it.
- **`WWI Stock Item ID` sourced from `_id`.** Don't look for a `StockItemID` field on
  the document; the value lives in `_id`.
