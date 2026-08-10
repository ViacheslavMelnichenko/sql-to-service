---
name: tsql-semantics
description: Use when converting a T-SQL stored procedure to a service — reads the proc's intent (LIKE/CONCAT null-swallowing, LEFT vs INNER join, TOP-N ordering, FOR JSON AUTO nesting, temporal FOR SYSTEM_TIME) so the port preserves observable behaviour, not just syntax
---

# T-SQL semantics → service intent

The failure mode this skill exists to stop: a port that is a **line-by-line
translation** of the SQL instead of a reproduction of what the SQL *observably
does*. The differential gate compares values, so every behaviour below is a value
the port must reproduce — getting the syntax "equivalent" is not enough.

Read the proc for these, in this order. Each is a real trap in this corpus.

## 1. `LIKE '%' + @x + '%'` over `CONCAT(...)` — NULL is swallowed, not propagated

`WHERE CONCAT(a, N' ', b, N' ', c) LIKE N'%' + @SearchText + N'%'`

- `CONCAT` **ignores NULL arguments** (treats them as `''`) — unlike `+`, which
  would make the whole expression NULL. So a row whose `b`/`c` is NULL still
  matches on `a`. This is a distinct branch (`SearchForCustomers` has a
  `null-contact-name-match` case for exactly it). A port that builds the search
  field with string `+` or that filters out NULL-contact rows drops that branch
  and fails the differential.
- The match is **case-/accent-insensitive** under WWI's default collation
  (`Latin1_General_100_CI_AS`). A case-sensitive `Contains` in the port is wrong.
- `%` and `_` in `@SearchText` are LIKE wildcards. The originals do not escape
  them; the port must match that (do not "helpfully" escape).

## 2. `INNER` vs `LEFT OUTER` JOIN — presence is a branch

`INNER JOIN Cities` means a customer with no matching city **disappears**;
`LEFT OUTER JOIN People` means a customer with a NULL contact **stays**, with the
contact columns NULL. The seed is built so both sides of each join are exercised
(a matched row and a NULL-contact row). In a document port over Mongo:
- an INNER join is a lookup that **must succeed** — a missing target drops the row;
- a LEFT join is a lookup that **may miss** — a missing target keeps the row and
  leaves the projected fields absent/NULL.
Confusing the two is the single most common silent bug.

## 3. `TOP(@n) ... ORDER BY` — the ORDER BY is *part of the contract*

`SELECT TOP(@MaximumRowsToReturn) ... ORDER BY c.CustomerName` returns the first
`n` rows **by that order**. Two obligations:
- **Order first, then limit.** Limiting an unordered set and then sorting the
  page is a different result (`top-1-pagination` case proves it: TOP(1) of "Toys"
  must be *Tailspin*, the first by name, not an arbitrary row).
- The order column may not be in the output shape, but it still determines *which*
  rows survive TOP. Keep it in the query even though it is not projected 1:1.

## 4. `FOR JSON AUTO, ROOT(...)` — the join shape becomes the document shape

This is the highest-risk conversion in the corpus. `FOR JSON AUTO` does **not**
emit flat rows; it **nests by table, in FROM/JOIN order**, keyed by **table
alias**:

```
FROM Sales.Customers AS c
INNER JOIN Application.Cities AS ct ...
LEFT  JOIN Application.People AS p ...
FOR JSON AUTO, ROOT(N'Customers')
```
produces (this is the actual golden):
```json
{"CustomerID":1,"CustomerName":"...","PhoneNumber":"...","FaxNumber":"...",
 "ct":[{"CityName":"Seattle",
        "p":[{"PrimaryContactFullName":"...","PrimaryContactPreferredName":"..."}]}]}
```
Rules `FOR JSON AUTO` applies, all of which the port must reproduce:
- Columns group under the **alias of the table they come from**: `c.*` at the top
  level, `ct.*` nested under key `"ct"`, `p.*` nested under `"p"`. **The nesting
  keys are the aliases** — `ct`, `p` — not the table names.
- Each deeper table is an **array**, even when the join is 1:1 (so `"ct":[{...}]`,
  not `"ct":{...}`).
- The `ROOT(N'Customers')` wraps the whole array — but note the capture reads the
  result set, so golden is the inner array; match what golden actually shows.
- **A LEFT JOIN that missed still emits the nested key with an empty object**:
  `"p":[{}]` (see the Wingtip row — NULL contact → `"p":[{}]`, not the key
  omitted, not `"p":[]`, not `"p":null`). Reproducing `[{}]` exactly is required.
- Column **key order inside each object follows the SELECT list**, but the gate
  canonicalises key order, so match values/nesting, not key order.

The service does this nesting **in code from flat Mongo documents** — Mongo has no
`FOR JSON AUTO`. That reconstruction is the conversion; see the
`document-modelling` skill for how to shape it.

## 5. `FOR SYSTEM_TIME AS OF @t` + cursor over `*_Archive` — point-in-time reconstruction

The three temporal procs (`GetCustomer/Supplier/CityUpdates`) walk
system-versioned history to emit **rows that changed inside a window**. What the
port must preserve:
- The **initial-load rows** (`ValidFrom` = `2013-01-01`) are **excluded** — the
  procs emit only genuine changes after load (`initial-load-excluded` case). A
  port that returns everything in the window fails.
- Each proc stages output through a `#...Changes` temp table with a **fixed column
  contract** (transcribed into the case file's `resultset`). The port's output
  columns and names must match that contract exactly (including `GetCityUpdates`'
  geography column literally named `geography`).
- `geography` is compared as **Well-Known-Text** (`POINT (lon lat)`); if the port
  models it as GeoJSON it must still be diffable to that WKT — the gate compares
  the WKT string.

## 6. `decimal` columns — never touch them as floats

WWI money/quantity are `decimal(18,4)`/`(18,2)`. Precision is a first-class part
of the output. Everything about the round-trip is in the `decimal-mapping` skill;
here just the rule: **a decimal never becomes a `double`/`float` anywhere in the
port.** One float cast and the differential catches you — that is what it is for.

## Checklist the reviewer applies

- [ ] `CONCAT`/`LIKE` search rebuilt so NULL parts are swallowed, not propagated;
      case-insensitive; wildcards not escaped.
- [ ] Each join classified INNER (drops) vs LEFT (keeps + null) and ported as such.
- [ ] `TOP(@n)` applied **after** `ORDER BY`; order column preserved in the query.
- [ ] `FOR JSON AUTO` nesting reproduced by alias, arrays even for 1:1, missed
      LEFT join → `[{}]`.
- [ ] Temporal: initial load excluded, `#Changes` column contract matched,
      geography as WKT.
- [ ] No `decimal` value passes through a binary float type.
