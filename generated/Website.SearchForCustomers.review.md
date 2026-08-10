# Review — `Website.SearchForCustomers`

*Written by the `reviewer` stage. Checks the generated service and tests against
the versioned skills and the golden contract, and records the gate result. This is
the showcase conversion for Phase 2 (task 2.9): one substantive proc carried by
hand through all four stages — analyst → implementer → test-author → reviewer.*

## Verdict: **PASS**

- **Builds:** `SearchForCustomers.csproj` and `tests/SearchForCustomers.Tests.csproj`
  both build with 0 errors on .NET 10. (Four `NU19xx` warnings are known-CVE
  advisories on *transitive* dependencies of `MongoDB.Driver` — `SharpCompress`,
  `Snappier` — not on generated code; noted, not blocking. A pinned-driver bump is a
  Phase-5 supply-chain item, not a conversion defect.)
- **Tests green:** 6/6 pass against the Mongo container on `:37017`. Five are the
  golden cases; the sixth pins the `"p":[{}]` empty-object shape directly.
- **Differential:** the *definition* of "matches golden" is exercised now — each
  test canonicalises both sides through the gate's own `corpus/canonicalise.py
  --ordered` and asserts equality, so a green test here is a green differential on
  that case. The standalone `gates/differential.sh` is a Phase-3 artifact; when it
  lands it re-runs the same comparison against a live-seeded DB with no new logic.
- **Oracle intact:** `git status corpus/` is clean — no golden or seed was touched
  to make anything pass.

## Skill-by-skill

**`tsql-semantics`**
- CONCAT null-swallowing: reproduced — the search field is built with
  `?? string.Empty` for the contact parts, so a NULL contact still matches on the
  customer name (`null-contact-name-match` green). ✔
- INNER vs LEFT: `DeliveryCityID → Cities` drops on miss (`continue`); 
  `PrimaryContactPersonID → People` keeps on miss (`person = null`). ✔
- LIKE: case-insensitive via `RegexOptions.IgnoreCase | CultureInvariant`; `%`/`_`
  translated to regex wildcards and not escaped, matching the raw-pattern original. ✔
- TOP after ORDER BY: `.OrderBy(...).Take(...)` in that order; `top-1-pagination`
  returns Tailspin, proving the page boundary. ✔

**`document-modelling`**
- Nesting keys are the aliases `ct`/`p`; each joined level is a one-element array
  even at 1:1; missed LEFT join emits `[{}]`; null-valued keys dropped via
  `AddIfPresent`. All four confirmed by the `Null_Contact_Emits_Empty_Object` test
  and the golden diffs. ✔
- Seed untouched — nesting built in service code, not by reshaping collections. ✔

**`decimal-mapping`**
- Not exercised (no `decimal` columns in this proc) but the negative check holds:
  grep finds no `double`/`float` anywhere in `generated/`. ✔

**`dotnet-service-shape`**
- One `SearchForCustomersService`, constructor-injected `IMongoDatabase`,
  `MongoDB.Driver`, no web/DI sprawl, `net10.0`. Runner (`Program.cs`) is thin and
  deterministic. `InvariantGlobalization`; ordinal/invariant comparisons; no clock,
  no random, no env reads. All source under `generated/`. ✔

## Notes for the next stages (not blockers)

- The runner reads a live Mongo on `:37017`; Phase 3's `differential.sh` should seed
  a fresh DB from `to_mongo.py` before invoking it, so the gate owns the seed rather
  than depending on ambient container state. The tests already do this (isolated
  `wwi_test_searchforcustomers` DB), which is the pattern to lift.
- The transitive-dependency CVE warnings want a driver-version decision in Phase 5
  `SECURITY.md`.
