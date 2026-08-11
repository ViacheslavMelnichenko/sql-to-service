# Spec: `Website.SearchForCustomers`

*Written by the `analyst` stage from `corpus/procs/Website.SearchForCustomers.sql`,
`corpus/cases/Website.SearchForCustomers.json`, and the five
`corpus/golden/Website.SearchForCustomers__*.json`. Intent, not translation.*

## Purpose
Given a free-text search string, the caller gets back a list of customers whose
name — or whose primary contact person's full/preferred name — contains that text,
each customer annotated with its delivery city and (if any) its primary contact
person. The result is a JSON document capped at a caller-supplied row count and
ordered by customer name.

## Parameters
| Param | Type | Role |
|-------|------|------|
| `SearchText` | `nvarchar(1000)` | Filter. Used as a **raw** `LIKE` substring pattern — see Filtering. |
| `MaximumRowsToReturn` | `int` | Row limit (`TOP`). Applied **after** ordering — see Ordering & limiting. |

## Data read
Three collections, joined customer → city → contact:

- `Sales_Customers` (alias `c`) — the driving set. One row per customer. Fields used:
  `CustomerID`, `CustomerName`, `PhoneNumber`, `FaxNumber`, `DeliveryCityID`
  (join key), `PrimaryContactPersonID` (join key).
- `Application_Cities` (alias `ct`) — joined **INNER** on
  `c.DeliveryCityID = ct.CityID`. Because it is INNER, a customer whose
  `DeliveryCityID` matches no city is **dropped entirely**. Field used: `CityName`.
  (In the seed every customer has a valid city, so this trap is not exercised by the
  golden — but it must be honoured: a city-less customer never appears.)
- `Application_People` (alias `p`) — joined **LEFT OUTER** on
  `c.PrimaryContactPersonID = p.PersonID`. Because it is LEFT, a customer with a
  NULL `PrimaryContactPersonID` (or a dangling id) is **kept**, just with the
  contact fields absent. Fields used: `FullName` (output as `PrimaryContactFullName`),
  `PreferredName` (output as `PrimaryContactPreferredName`).

In the seed, customer 1 (Tailspin Toys) has contact person 3 (Cara); customer 2
(Wingtip Toys) has `PrimaryContactPersonID = null` — the LEFT-join-miss branch.

## Filtering
Single predicate:

```
CONCAT(c.CustomerName, ' ', p.FullName, ' ', p.PreferredName) LIKE '%' + @SearchText + '%'
```

Behavioural rules the port must reproduce exactly:

- **`CONCAT` treats NULL as empty string.** When the contact person is absent
  (`p.FullName`/`p.PreferredName` are NULL), those pieces contribute nothing — the
  match still runs against `CustomerName` alone (plus the two literal spaces). Do
  **not** implement this with a `+` concatenation (which would null the whole
  expression and silently drop NULL-contact customers). Do **not** filter out
  NULL-contact rows. The `null-contact-name-match` case proves Wingtip (NULL
  contact) matches on its own name.
- **The contact side genuinely contributes to the match.** `contact-name-match`
  ("Cara") matches customer 1 only via `p.FullName`/`p.PreferredName`, so the
  concatenated haystack must include the contact fields.
- **Case-insensitive substring match.** WWI's default collation is
  `Latin1_General_100_CI_AS` — `LIKE` is case-insensitive (accent-sensitive).
  `Cara`, `cara`, `CARA` all match. A naive `string.Contains` is case-sensitive; use
  a case-insensitive comparison.
- **`SearchText` is a raw `LIKE` pattern.** It is dropped between two `%` wildcards
  with **no escaping**. `%`, `_`, `[` in the search text act as `LIKE`
  metacharacters. The golden cases use only plain words, but the port must preserve
  substring (`contains`) semantics and not pre-escape the input.
- The haystack layout is `CustomerName + ' ' + FullName + ' ' + PreferredName`
  (single spaces between the three parts, even when a part is empty). A search string
  spanning a space boundary would hit this join text — an edge worth keeping
  faithful, though no golden case exercises it.

## Ordering & limiting
`ORDER BY c.CustomerName` is applied **first**, then `TOP(@MaximumRowsToReturn)`
takes the leading N rows. **Order first, then take** — `TOP(1)` returns the
alphabetically-first customer, not an arbitrary one. `top-1-pagination` proves this:
"Toys" matches both Tailspin and Wingtip, but `TOP(1)` yields `Tailspin Toys (Head)`
(T sorts before W).

The case contract sets `ordered: true`: the row order in the output array is part
of the contract and must not be re-sorted or canonicalised away.

## Output shape (`for-json`, `ordered: true`)
`FOR JSON AUTO, ROOT('Customers')` nests by table alias in join order. The capture
reads the inner array (the `Customers` root wrapper is unwrapped), so a golden row
looks like:

```json
{"CustomerID":1,"CustomerName":"Tailspin Toys (Head)","FaxNumber":"555-0101",
 "PhoneNumber":"555-0100",
 "ct":[{"CityName":"Seattle",
        "p":[{"PrimaryContactFullName":"Cara Customer",
              "PrimaryContactPreferredName":"Cara"}]}]}
```

Shape rules the port must reproduce exactly:

- **Top level** = the `c.*` fields. The golden key order is
  **`CustomerID, CustomerName, FaxNumber, PhoneNumber`** — note `FaxNumber` comes
  **before** `PhoneNumber`, which is *not* the SELECT-list order. Reproduce the
  golden's key order.
- **City nests under key `ct`** (the alias) as a **one-element array**:
  `"ct":[{"CityName":...}]`.
- **Contact nests under key `p`** (the alias) as a one-element array **inside** the
  `ct` object: `"ct":[{"CityName":...,"p":[{...}]}]`. Nesting follows join order —
  people is joined after cities, so `p` sits inside `ct`, not at the top level.
- **Missed LEFT join → `"p":[{}]`** — the array is present with a single **empty
  object** (customer 2). NOT omitted, NOT `[]`, NOT `null`.
- **`FOR JSON` omits any NULL-valued key at every level.** That is *why* the empty
  contact object is `{}` and not full of nulls, and it applies equally to any
  top-level or city field that is NULL. Reproduce by dropping null keys.
- **Empty result → `[]`.** No matching row produces an empty JSON array
  (`no-match-empty`).

## Per-case expectations
| Case | SearchText | Max | Golden |
|------|-----------|-----|--------|
| `toys-both` | `Toys` | 100 | Both customers, ordered Tailspin (1) then Wingtip (2). Customer 1 has full contact `p:[{Cara...}]`; customer 2 shows `p:[{}]`. |
| `contact-name-match` | `Cara` | 100 | Customer 1 only — matched via the contact's name through the LEFT join, proving the contact contributes to the CONCAT haystack. |
| `null-contact-name-match` | `Wingtip` | 100 | Customer 2 only — NULL-contact customer still returned via its own name; contact renders as `p:[{}]`. |
| `no-match-empty` | `zzz` | 100 | Empty array `[]`. |
| `top-1-pagination` | `Toys` | 1 | Customer 1 (Tailspin) only — order-before-limit gives the alphabetically first of the two matches. |

## Precision-sensitive fields
None — this proc surfaces no `decimal`/`money` columns. All output fields are
integers or strings. The implementer must still not introduce a float anywhere.

## Open risks for the implementer
- **Empty-object vs. absent for the missed LEFT join.** The `"p":[{}]` form is the
  single most likely miss — implementers tend to emit `[]`, `null`, or drop the `p`
  key. It must be a one-element array holding an empty object.
- **Contact nesting depth.** `p` nests inside the `ct` array (`ct[0].p`), not at the
  top level. Getting it to the wrong level is a common shape error; the golden pins
  it inside `ct`.
- **Top-level key order (`FaxNumber` before `PhoneNumber`).** Differs from the
  SELECT list; match the golden.
- **CONCAT NULL-coalescing.** Modelling the haystack with anything that nulls-out on
  a missing contact will wrongly exclude NULL-contact customers. Treat missing
  contact name parts as empty strings.
- **Case-insensitivity.** Use a case-insensitive comparison, not a default
  culture/ordinal `Contains`.
- **Unescaped wildcards.** `SearchText` flows straight into a `LIKE` pattern;
  preserve substring semantics and do not pre-escape.
- **INNER city join drop.** Not exercised by the seed, but a customer with no
  matching city must be omitted entirely — do not soften this to a LEFT join.
