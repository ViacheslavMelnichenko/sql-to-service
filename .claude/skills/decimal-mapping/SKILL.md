---
name: decimal-mapping
description: Use when a converted service reads or emits numeric columns from Mongo — enforces decimal → Decimal128 with no float anywhere, fixed scale 4, string round-trip matching to_mongo.py and canonicalise.py, so the precision bug the artifact exists to catch cannot slip through
---

# `decimal` → `Decimal128` round-trip rules

This is the precision thesis of the whole artifact, stated as law. WWI money and
quantity columns are `decimal(18,4)` and `decimal(18,2)`. A migration that lets one
of them touch a binary float loses digits **silently** — the exact class of bug the
differential gate is built to catch. So the rule is absolute, not situational.

## The one rule

**A `decimal` value never becomes a `double` or `float` at any point** — not in the
Mongo document, not in the C# model, not in an intermediate calculation, not in the
serialisation to JSON. It is `Decimal128` in Mongo and `decimal` (C#
`System.Decimal`) in code, end to end.

## Why a float loses — concretely

`decimal(18,4)` can hold `123456789012.3456` exactly. `double` has ~15–17
significant decimal digits, so that value round-trips to `123456789012.3455` or
`...3457` depending on platform. The differential compares the fixed-scale string,
so `"123456789012.3456"` vs `"123456789012.3455"` is a **fail** — correctly. There
is no float wide enough; the answer is "don't use float," not "use a wider float."

## How it flows through the pipeline (match these exactly)

1. **Capture** (`capture-golden.py`): `FOR JSON` emits decimals as JSON **strings**,
   preserving digits. Golden carries them as strings.
2. **Canonical form** (`canonicalise.py`): both sides are normalised to a
   **fixed-scale string at scale 4** before comparison
   (`DEFAULT_SCALE = 4`). `12.5` becomes `"12.5000"`; `12` from a decimal column
   becomes `"12.0000"`. Integers from **integer** columns stay bare ints.
3. **Mongo seed** (`to_mongo.py`): decimals become
   `{"$numberDecimal": "<fixed-scale string>"}` → BSON `Decimal128`. Never a
   `$numberDouble`. The seed already carries the exact digits; the service must not
   degrade them.

The service sits between (3) and the differential. Its job: read `Decimal128` →
`System.Decimal` → emit at scale 4 as a string. If every hop is `decimal`, it
round-trips by construction.

## C# rules for the implementer

- Model decimal columns as `decimal` (not `double`, not `float`, not `object`).
- Read from Mongo with the BSON `Decimal128` → `decimal` conversion
  (`Decimal128.ToDecimal()` / the driver's `[BsonRepresentation(BsonType.Decimal128)]`
  on a `decimal` property). Do **not** deserialize into `double`.
- Any arithmetic (there is little in this corpus, but temporal/aggregate ports may
  add some) stays in `decimal`.
- Serialise to the comparison JSON as a **fixed-scale string**, scale 4, matching
  `canonicalise.py`. `value.ToString("F4", CultureInfo.InvariantCulture)` gives
  `"12.5000"`. Use `InvariantCulture` — a comma decimal separator from a locale is
  a silent differential fail.
- **Integer** columns (`int`, `bigint` — IDs, counts, `PaymentDays`) stay integers,
  not decimals. Do not blanket-quantise everything; scale 4 is for the decimal
  columns only. Over-quantising an int column to `"5.0000"` is also a fail.

## What the reviewer checks

- [ ] No `double`/`float` type appears anywhere a decimal column is read, stored,
      computed, or emitted (grep the generated service).
- [ ] Decimal Mongo fields are `Decimal128`-mapped to `System.Decimal`.
- [ ] Emitted decimals are fixed-scale strings at scale 4, `InvariantCulture`.
- [ ] Integer columns stay integers — not quantised to scale-4 strings.
- [ ] A spot value from golden (e.g. a `decimal(18,2)` amount) matches
      digit-for-digit after canonicalisation.
