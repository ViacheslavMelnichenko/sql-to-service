using System.Text.Json;
using MongoDB.Driver;
using SqlToService.Generated;

// Thin, deterministic runner so gates/differential.sh can capture the service's
// output for a case and diff it against golden. It does no logic of its own:
// connect, run the service for the given params, print JSON to stdout.
//
// UNIFORM RUNNER CONTRACT (B.1) — every converted proc's runner takes the same argv:
//
//   <binary> '<paramsJson>' [mongoUri]
//
// paramsJson is the case's `params` verbatim from corpus/cases/<Proc>.json — a JSON
// array of {"name","type","value"} objects. The runner reads its own parameters out
// of that array by name, so the differential passes the case file's params through
// with zero per-proc knowledge of argument names, order, or types.
//
// Output is a JSON array of the nested customer documents, in the service's order.
// The differential passes it through corpus/canonicalise.py --ordered before
// comparing, so key order / whitespace here do not matter; values and shape do.

if (args.Length < 1)
{
    Console.Error.WriteLine("usage: SearchForCustomers '<paramsJson>' [mongoUri]");
    return 2;
}

var byName = ParseParams(args[0]);
var searchText = RequireString(byName, "SearchText");
var maxRows = RequireInt(byName, "MaximumRowsToReturn");
var uri = args.Length >= 2 ? args[1] : "mongodb://localhost:37017/wwi";

var client = new MongoClient(uri);
var db = client.GetDatabase(MongoUrl.Create(uri).DatabaseName ?? "wwi");

var service = new SearchForCustomersService(db);
var result = service.Execute(searchText, maxRows);

var json = JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = false });
Console.WriteLine(json);
return 0;

// --- param plumbing (the uniform contract's reader) --------------------------------

// Parse the case file's `params` array into a name -> JsonElement map. Accepts both
// the array-of-objects form ([{"name","value"}, ...], the case-file shape) and a
// flat {name: value} object, so a caller can hand either.
static Dictionary<string, JsonElement> ParseParams(string paramsJson)
{
    var map = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
    using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(paramsJson) ? "[]" : paramsJson);
    var root = doc.RootElement;
    if (root.ValueKind == JsonValueKind.Array)
    {
        foreach (var item in root.EnumerateArray())
            map[item.GetProperty("name").GetString()!] = item.GetProperty("value").Clone();
    }
    else if (root.ValueKind == JsonValueKind.Object)
    {
        foreach (var prop in root.EnumerateObject())
            map[prop.Name] = prop.Value.Clone();
    }
    return map;
}

static string RequireString(Dictionary<string, JsonElement> p, string name)
{
    if (!p.TryGetValue(name, out var v))
        throw new ArgumentException($"missing required parameter '{name}'");
    return v.ValueKind == JsonValueKind.String ? v.GetString()! : v.GetRawText();
}

static int RequireInt(Dictionary<string, JsonElement> p, string name)
{
    if (!p.TryGetValue(name, out var v))
        throw new ArgumentException($"missing required parameter '{name}'");
    // The case file stores ints as JSON numbers; tolerate a quoted number too.
    return v.ValueKind == JsonValueKind.Number
        ? v.GetInt32()
        : int.Parse(v.GetString()!, System.Globalization.CultureInfo.InvariantCulture);
}
