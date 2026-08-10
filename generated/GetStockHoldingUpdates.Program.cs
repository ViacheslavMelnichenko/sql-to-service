using System.Text.Json;
using MongoDB.Driver;
using SqlToService.Generated;

// Thin, deterministic runner for Integration.GetStockHoldingUpdates, so
// gates/differential.sh can capture the service's output and diff it against golden.
// It does no logic of its own: connect, run the service, print JSON to stdout.
//
// UNIFORM RUNNER CONTRACT (B.1) — every converted proc's runner takes the same argv:
//
//   <binary> '<paramsJson>' [mongoUri]
//
// paramsJson is the case's params as a single JSON value: either the array the case
// file stores ([{"name":..,"value":..}, ...]) or a flat {name: value} object. The
// differential passes corpus/cases/<Proc>.json's `params` verbatim, so it needs no
// per-proc knowledge of argument names or order. This proc is zero-parameter, so the
// value is empty ("[]" / "{}") and ignored — but the contract is identical across
// the corpus, which is the whole point of B.1.
//
// Output is a JSON array of the flat result rows, in the service's order (ORDER BY
// StockItemID). The differential passes it through corpus/canonicalise.py --ordered
// before comparing, so key order / whitespace here do not matter; values and shape do.

var uri = args.Length >= 2 ? args[1] : "mongodb://localhost:37017/wwi";
// args[0] (paramsJson) is accepted for contract uniformity and intentionally unused:
// this proc has no parameters. Parsing-and-ignoring keeps the runner honest about the
// contract without inventing behaviour the original does not have.

var client = new MongoClient(uri);
var db = client.GetDatabase(MongoUrl.Create(uri).DatabaseName ?? "wwi");

var service = new GetStockHoldingUpdatesService(db);
var result = service.Execute();

var json = JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = false });
Console.WriteLine(json);
return 0;
