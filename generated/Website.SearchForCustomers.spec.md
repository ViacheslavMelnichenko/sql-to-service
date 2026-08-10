# Spec — `Website.SearchForCustomers`

*Written by the `analyst` stage from `corpus/procs/Website.SearchForCustomers.sql`,
`corpus/cases/Website.SearchForCustomers.json`, and the five
`corpus/golden/Website.SearchForCustomers__*.json`. Intent, not translation.*

## Purpose

Free-text search over customers: given a search string and a maximum row count,
return the matching customers (with their city and primary contact) as a nested
JSON document, ordered by customer name.

## Parameters

| Param | Type | Role |
|-------|------|------|
| `SearchText` | `nvarchar(1000)` → `string` | The substring to search for. Raw LIKE pattern — `%`/`_` are wildcards, not escaped. |
| `MaximumRowsToReturn` | `int` | Row cap, applied **after** ordering (a TOP-N page). |

## Data read

Three collections, joined customer → city → contact:

- `Sales_Customers` (alias `c`) — the driving set. Fields used: `CustomerID`,
  `CustomerName`, `PhoneNumber`, `FaxNumber`, `DeliveryCityID` (join key),
  `PrimaryContactPersonID` (join key).
- `Application_Cities` (alias `ct`) — **INNER** join on
  `c.DeliveryCityID = ct.CityID`. A customer with no matching city is **dropped**.
  Field used: `CityName`.
- `Application_People` (alias `p`) — **LEFT OUTER** join on
  `c.PrimaryContactPersonID = p.PersonID`. A customer with a NULL contact is
  **kept**, with the contact fields absent. Fields used: `FullName` (output as
  `PrimaryContactFullName`), `PreferredName` (output as
  `PrimaryContactPreferredName`).

In the seed, every customer has a valid city (INNER always succeeds here); customer
1 has contact person 3 (Cara), customer 2 has `PrimaryContactPersonID = NULL` — the
LEFT-join-miss branch.

## Filtering

`WHERE CONCAT(c.CustomerName, ' ', p.FullName, ' ', p.PreferredName) LIKE '%' + @SearchText + '%'`

Behaviourally:
- Build a search field by concatenating the customer name, the contact full name,
  and the contact preferred name with single spaces. **`CONCAT` treats NULL as an
  empty string** — so for customer 2 (NULL contact) the field is just the customer
  name plus two spaces, and it still matches on the name. Do **not** use string `+`
  (which would null the whole field) and do **not** filter out NULL-contact rows.
- The match is a **case-insensitive** substring (WWI default collation
  `Latin1_General_100_CI_AS`). `Cara`, `cara`, `CARA` all match.
- `@SearchText` is used as a raw LIKE pattern; wildcards inside it are not escaped.

## Ordering & limiting

`ORDER BY c.CustomerName`, then `TOP(@MaximumRowsToReturn)`. **Order first, then
take.** `CustomerName` decides which rows survive the cap. `Tailspin Toys (Head)`
sorts before `Wingtip Toys`.

## Output shape (`for-json`, `ordered: true`)

`FOR JSON AUTO, ROOT('Customers')` nests by table alias, in join order. The capture
reads the inner array, so a golden row looks like:

```json
{"CustomerID":1,"CustomerName":"Tailspin Toys (Head)","PhoneNumber":"555-0100",
 "FaxNumber":"555-0101",
 "ct":[{"CityName":"Seattle",
        "p":[{"PrimaryContactFullName":"Cara Customer",
              "PrimaryContactPreferredName":"Cara"}]}]}
```

Shape rules the port must reproduce exactly:
- Top level = `c.*` fields.
- City nests under key **`ct`** (the alias), as a **one-element array**:
  `"ct":[{...}]`.
- Contact nests under key **`p`** (the alias), a one-element array **inside** the
  `ct` object.
- **Missed LEFT join → `"p":[{}]`** — the array is present with a single empty
  object (customer 2). Not omitted, not `[]`, not `null`.
- **`FOR JSON` omits any NULL-valued key** at every level. That is *why* the empty
  contact object is `{}` and not full of nulls. Reproduce by dropping null keys.
- Output is **ordered** by `CustomerName` (do not sort/canonicalise row order away
  — `ordered: true`).

## Per-case expectations

| Case | Params | Golden |
|------|--------|--------|
| `toys-both` | `Toys`, 100 | Both customers (Tailspin then Wingtip). Customer 2 shows `"p":[{}]`. |
| `contact-name-match` | `Cara`, 100 | Customer 1 only — matched via the contact's name through the LEFT join. |
| `null-contact-name-match` | `Wingtip`, 100 | Customer 2 only — NULL contact, matches on name because CONCAT ignores the NULL. |
| `no-match-empty` | `zzz`, 100 | Empty result → golden `[]`. |
| `top-1-pagination` | `Toys`, 1 | Only Tailspin — TOP(1) after ordering by name. |

## Precision-sensitive fields

None. All output fields are strings/ints; no `decimal` columns in this proc. (The
decimal round-trip thesis lives in the `Get*Updates` money procs, not here.) The
implementer still must not introduce a float anywhere.

## Open risks for the implementer

- The empty-contact object `{}` vs an omitted `p` key vs `null` — get the `[{}]`
  exactly; it is the single most likely miss.
- Case-insensitivity: a naive `string.Contains` is case-sensitive; use a
  collation/regex-insensitive match.
- Order-before-limit for the `top-1` case.
