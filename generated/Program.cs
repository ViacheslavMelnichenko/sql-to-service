using System.Text.Json;
using MongoDB.Driver;
using SqlToService.Generated;

// Thin, deterministic runner so gates/differential.sh can capture the service's
// output for a case and diff it against golden. It does no logic of its own:
// connect, run the service for the given params, print JSON to stdout.
//
//   SearchForCustomers "<SearchText>" <MaximumRowsToReturn> [mongoUri]
//
// Output is a JSON array of the nested customer documents, in the service's order.
// The differential passes it through corpus/canonicalise.py --ordered before
// comparing, so key order / whitespace here do not matter; values and shape do.

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: SearchForCustomers <SearchText> <MaximumRowsToReturn> [mongoUri]");
    return 2;
}

var searchText = args[0];
if (!int.TryParse(args[1], System.Globalization.NumberStyles.Integer,
        System.Globalization.CultureInfo.InvariantCulture, out var maxRows))
{
    Console.Error.WriteLine($"MaximumRowsToReturn must be an int, got: {args[1]}");
    return 2;
}
var uri = args.Length >= 3 ? args[2] : "mongodb://localhost:37017/wwi";

var client = new MongoClient(uri);
var db = client.GetDatabase(MongoUrl.Create(uri).DatabaseName ?? "wwi");

var service = new SearchForCustomersService(db);
var result = service.Execute(searchText, maxRows);

var json = JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = false });
Console.WriteLine(json);
return 0;
