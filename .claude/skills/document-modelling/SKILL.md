---
name: document-modelling
description: Use when a converted service must reconstruct a FOR JSON AUTO result (or any nested output) from the flat Mongo collections — governs how to reshape flat documents into the golden's nested shape without changing the seed, and where document modelling is the agent's decision vs fixed by the oracle
---

# Result-set → Mongo document modelling

The seed is **flat by law** (ADR-0003, `to_mongo.py`): one relational table → one
collection, columns verbatim, no embedding, no joins. That flatness is deliberate —
it keeps the Mongo side from being pre-fitted to the answer. So the nesting that
`FOR JSON AUTO` produces on the SQL side does **not** exist in the seed. Rebuilding
it is the conversion, and it happens **in the service code**, at query/projection
time — never by reshaping the seed.

## The two decisions, kept separate

- **Output shape is fixed by the oracle.** The golden JSON is the contract. The
  service's output — nesting keys, arrays vs objects, which fields, null handling —
  must equal golden after canonicalisation. This is not the agent's to choose.
- **How to get there from flat collections is the agent's conversion decision.**
  Server-side `$lookup` aggregation, or N+1 client-side lookups, or load-and-join
  in C# — all legitimate if the *output* matches. Prefer the shape that reads as
  idiomatic .NET+Mongo (see `dotnet-service-shape`), but the gate judges output,
  not method.

## Reproducing `FOR JSON AUTO` nesting from flat docs

Worked from `SearchForCustomers` (the showcase). SQL joins
`Customers c → Cities ct → People p` and `FOR JSON AUTO` nests by alias:

```json
{"CustomerID":1,"CustomerName":"...","PhoneNumber":"...","FaxNumber":"...",
 "ct":[{"CityName":"Seattle",
        "p":[{"PrimaryContactFullName":"...","PrimaryContactPreferredName":"..."}]}]}
```

Mapping flat → nested, the rules that bite:

1. **Nesting key = table alias, not collection name.** `ct` and `p`, not `Cities`
   / `Application_People`. The aliases come from the *original proc's* FROM clause —
   read them there, do not invent readable names.
2. **Every joined level is an array even when 1:1.** `"ct":[{...}]`, `"p":[{...}]`.
   Emit a single-element array, not a bare object.
3. **A LEFT-join miss emits `[{}]`, not omission.** Customer 2 has a NULL contact,
   so `FOR JSON AUTO` still emits `"p":[{}]` — the array is present, its one object
   is empty because every projected `p.*` column was NULL and `FOR JSON` **omits
   null-valued keys**. So the port must:
   - keep the nested array present for a missed LEFT join (`[{}]`),
   - and **drop keys whose value is NULL** inside each object (that is why the
     empty object is `{}` and not `{"PrimaryContactFullName":null,...}`).
4. **INNER-join level is never empty.** `ct` (Cities, INNER) always has its one
   populated object; a customer with no city would have been dropped upstream — so
   an empty `ct` in output means the join was ported as LEFT by mistake.
5. **`FOR JSON` omits any null column, at every level.** This is why the top-level
   objects in golden never carry a `null` field — verify the port drops nulls the
   same way rather than emitting `"X":null`.

## Field selection

Project **only** the columns the SELECT lists, at the level their table sits.
`c.CustomerID, c.CustomerName, c.PhoneNumber, c.FaxNumber` at the top;
`ct.CityName` under `ct`; `p.FullName AS PrimaryContactFullName`,
`p.PreferredName AS PrimaryContactPreferredName` under `p`. **Aliases in the SELECT
are output field names** — `PrimaryContactFullName`, not `FullName`. Do not carry
extra fields "for completeness"; an extra key is a differential fail.

## Tabular procs (the `Get*Updates`) — no nesting

The nine `Get*Updates` procs return a **flat table**, not JSON — their case files
declare `"shape": "tabular"`. For these the document model is trivial: one flat
object per row, keys = the `#...Changes` column contract, no arrays, no nesting.
The modelling effort is entirely in the temporal reconstruction (which rows), not
the shape (see `tsql-semantics` §5).

## What the reviewer checks

- [ ] Seed untouched — nesting is built in service code, not by editing collections.
- [ ] Nesting keys are the proc's **aliases**; joined levels are **arrays** even 1:1.
- [ ] Missed LEFT join → `[{}]`; null-valued keys dropped at every level.
- [ ] Only SELECT-listed columns present, under the right level, with SELECT aliases.
- [ ] Tabular procs emit flat objects with the exact `#Changes` column contract.
