---
name: dotnet-service-shape
description: Use when writing or reviewing the generated .NET service for a converted proc — defines the idiomatic, minimal, deterministic service shape (one class per proc, MongoDB.Driver, decimal-safe, culture-invariant, no framework sprawl) that builds under the gate and is diffable against golden
---

# Idiomatic .NET service shape

The generated service is judged two ways: it must **build** (PostToolUse hook,
`gates/build.sh`) and its output must **match golden** (`gates/differential.sh`).
Everything below serves those two, plus a third that is not automatable but matters
to the reviewer: it should read like code a competent .NET engineer would write,
not like a transpiler's output.

## Shape

- **One method per procedure**, on a class named `<Proc>Service` (e.g.
  `SearchForCustomersService`). The method signature mirrors the proc's parameters,
  typed as their C# equivalents (`string searchText, int maximumRowsToReturn`).
- **Return the shape the golden declares.** For `for-json` procs, return the nested
  object graph (anonymous objects / `Dictionary`/`BsonDocument` are all fine as
  long as it serialises to golden). For `tabular` procs, return
  `IReadOnlyList<T>` of a flat row record.
- **`MongoDB.Driver`** is the data access. `IMongoDatabase` injected into the
  constructor — do not new up a `MongoClient` inside the method (untestable, and
  the test-author needs to inject a seeded database).
- **No web layer, no DI container, no controllers** unless the proc's contract
  needs it. This corpus is service classes, not ASP.NET apps. A `.csproj` targeting
  the repo's pinned .NET with `MongoDB.Driver` is the whole project.
- **Target the toolchain that is installed** (`dotnet --version`; this repo is on
  .NET 10). Use `net10.0` TFM unless a gate says otherwise.

## Correctness rules that are easy to get wrong

- **Decimals:** follow the `decimal-mapping` skill without exception —
  `System.Decimal` end to end, `Decimal128` from Mongo, fixed-scale-4
  `InvariantCulture` string on output. This is the most-reviewed line.
- **Culture:** every `ToString`/parse of a number or date uses
  `CultureInfo.InvariantCulture`. A locale-formatted number is a silent
  differential fail.
- **Ordering + limit:** apply `ORDER BY` **before** `Take(n)` (LINQ) or in the
  Mongo `.Sort(...).Limit(n)` pipeline — never the reverse (see `tsql-semantics`
  §3).
- **Case-insensitive search:** match WWI's `CI_AS` collation — a Mongo regex with
  the `i` option or a case-insensitive collation, not `string.Contains` in C#
  (which is culture/case-sensitive by default). Do not escape `%`/`_` semantics
  away; the original treats `@SearchText` as a raw LIKE pattern.
- **Null handling / nesting:** follow `document-modelling` — drop null keys, missed
  LEFT join → `[{}]`, joined levels are arrays.
- **Determinism:** no `DateTime.Now`, no `Guid.NewGuid()`, no random, no
  environment reads in the output path. The differential re-runs must be identical.

## Serialisation

The service's output is compared as JSON after `canonicalise.py`, so:
- Emit via `System.Text.Json` (or the driver's serialisation) — but the **canonical
  form is what is compared**, so key order and whitespace do not matter; **values,
  nesting, presence/absence of keys, and decimal scale do.**
- Provide the output in a way `gates/differential.sh` can capture — typically a
  small runner (`Program.cs` / a test) that invokes the method for a case's params
  and writes the JSON to stdout. Keep that runner thin and deterministic.

## Project hygiene

- Everything the service needs lives under `generated/` (the `PreToolUse` hook
  blocks writes elsewhere). One `.csproj`, source files, nothing generated into the
  repo root.
- No unused usings, no dead scaffolding, no commented-out alternatives. The
  reviewer reads this top to bottom.
- Nullable reference types on; warnings-as-errors is welcome but not required —
  `build.sh` decides.

## What the reviewer checks

- [ ] One `<Proc>Service` class, constructor-injected `IMongoDatabase`, one method
      per proc, parameters typed to the proc's.
- [ ] `MongoDB.Driver`; no web/DI sprawl; TFM matches the installed toolchain.
- [ ] Decimal-safe (`decimal-mapping`), culture-invariant everywhere.
- [ ] Order-before-limit; case-insensitive search matching collation.
- [ ] Output reshaping follows `document-modelling`; deterministic (no clock/random).
- [ ] Builds clean under `gates/build.sh`; a thin runner lets the differential
      capture output; all files under `generated/`.
