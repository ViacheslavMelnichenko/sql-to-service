using System.Diagnostics;
using System.Text;
using System.Text.Json;
using MongoDB.Bson;
using MongoDB.Driver;
using SqlToService.Generated;
using Xunit;

namespace SqlToService.Generated.Tests;

// Unit tests for the converted Integration.GetStockHoldingUpdates service. Written
// from the SPEC and GOLDEN, NOT from the implementation's reasoning (ADR-0001/0004):
// each test asserts the service output equals the golden AFTER the same canonical
// form the differential gate uses (corpus/canonicalise.py --ordered). Where a
// contract detail is too important to let canonicalisation launder it (the decimal
// string trap; JSON string-vs-number; row order), it is pinned directly on the raw
// serialised output too.
//
// This proc's whole reason for being in the corpus is the decimal round-trip
// (LastCostPrice decimal(18,2) -> Decimal128 -> JSON), so beyond the golden match
// there are direct assertions that the money value surfaces as the exact
// fixed-scale STRING "12.5000"/"8.0000" (quoted, trailing zeros) and is NOT emitted
// through a lossy double, while the integer fields stay unquoted numbers. That is
// the precision mutant's target.
//
// Requires the Mongo container on :37017. Seeds a fresh, isolated database with the
// flat documents to_mongo.py would emit for Warehouse.StockItemHoldings: StockItemID
// -> _id, LastCostPrice -> Decimal128 at fixed scale 4 (NEVER a double), two rows.
public sealed class GetStockHoldingUpdatesTests : IDisposable
{
    private readonly string _dbName = "wwi_test_getstockholdingupdates";
    private readonly MongoClient _client;
    private readonly IMongoDatabase _db;
    private readonly string _repoRoot;

    public GetStockHoldingUpdatesTests()
    {
        _client = new MongoClient("mongodb://localhost:37017");
        _client.DropDatabase(_dbName);
        _db = _client.GetDatabase(_dbName);
        _repoRoot = FindRepoRoot();
        Seed();
    }

    public void Dispose() => _client.DropDatabase(_dbName);

    // The flat seed, exactly as to_mongo.py would produce it from relational.json:
    // StockItemID -> _id, and LastCostPrice decimal -> Decimal128 at fixed scale 4
    // ({"$numberDecimal":"12.5000"}), NEVER a double. Seeded in reverse id order so a
    // service that forgot to ORDER BY _id could not pass the order assertions by luck.
    private void Seed()
    {
        _db.GetCollection<BsonDocument>("Warehouse_StockItemHoldings").InsertMany(new[]
        {
            Holding(2, "L-2", qtyOnHand: 50, lastStocktake: 50, lastCost: "8.0000",
                    reorder: 10, target: 100),
            Holding(1, "L-1", qtyOnHand: 100, lastStocktake: 95, lastCost: "12.5000",
                    reorder: 20, target: 200),
        });
    }

    private static BsonDocument Holding(int id, string bin, int qtyOnHand, int lastStocktake,
        string lastCost, int reorder, int target) => new()
    {
        { "_id", id },
        { "BinLocation", bin },
        { "QuantityOnHand", qtyOnHand },
        { "LastStocktakeQuantity", lastStocktake },
        // Decimal128 at fixed scale 4, mirroring to_mongo.py's Decimal128 seed value
        // exactly (Decimal128.Parse preserves the scale of the literal). A double
        // here would defeat the round-trip the test exists to exercise.
        { "LastCostPrice", new BsonDecimal128(Decimal128.Parse(lastCost)) },
        { "ReorderLevel", reorder },
        { "TargetStockLevel", target },
    };

    // ---- 1. Golden match, canonicalised the same way the gate compares. ----
    // The only case in corpus/cases: zero-param -> the whole table, ordered by _id.
    [Theory]
    [InlineData("all-holdings")]
    public void Matches_Golden(string caseName)
    {
        var service = new GetStockHoldingUpdatesService(_db);
        var actual = service.Execute();

        var actualCanon = Canonicalise(JsonSerializer.Serialize(actual));
        var goldenPath = Path.Combine(_repoRoot, "corpus", "golden",
            $"Integration.GetStockHoldingUpdates__{caseName}.json");
        var goldenCanon = Canonicalise(File.ReadAllText(goldenPath));

        Assert.Equal(goldenCanon, actualCanon);
    }

    // ---- 2. Row count and contractual order (ordered: true). ----
    // Two rows, ordered by WWI Stock Item ID (_id) ascending: 1 then 2. Because the
    // seed is inserted 2-then-1, this fails for any service that doesn't sort.
    [Fact]
    public void Returns_Two_Rows_Ordered_By_StockItemId_Ascending()
    {
        var service = new GetStockHoldingUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute()));

        Assert.Equal(JsonValueKind.Array, doc.RootElement.ValueKind);
        Assert.Equal(2, doc.RootElement.GetArrayLength());
        Assert.Equal(1, doc.RootElement[0].GetProperty("WWI Stock Item ID").GetInt32());
        Assert.Equal(2, doc.RootElement[1].GetProperty("WWI Stock Item ID").GetInt32());
    }

    // ---- 3. Every projected field for both rows equals the golden. ----
    // Read the values straight from the golden file so the assertion cannot drift
    // from the oracle. Uses the raw (non-canonical) output, matched positionally in
    // the contractual id order, so a wrong value in ANY column fails loudly.
    [Fact]
    public void Every_Field_Matches_Golden_For_Both_Rows()
    {
        var service = new GetStockHoldingUpdatesService(_db);
        using var actual = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute()));

        var goldenPath = Path.Combine(_repoRoot, "corpus", "golden",
            "Integration.GetStockHoldingUpdates__all-holdings.json");
        using var golden = JsonDocument.Parse(File.ReadAllText(goldenPath));

        Assert.Equal(golden.RootElement.GetArrayLength(), actual.RootElement.GetArrayLength());

        for (var i = 0; i < golden.RootElement.GetArrayLength(); i++)
        {
            var g = golden.RootElement[i];
            var a = actual.RootElement[i];

            AssertSameString(g, a, "Bin Location");
            AssertSameString(g, a, "Last Cost Price"); // decimal is a JSON string
            AssertSameInt(g, a, "Last Stocktake Quantity");
            AssertSameInt(g, a, "Quantity On Hand");
            AssertSameInt(g, a, "Reorder Level");
            AssertSameInt(g, a, "Target Stock Level");
            AssertSameInt(g, a, "WWI Stock Item ID");
        }
    }

    // ---- 4. THE DECIMAL TRAP — the highest-value assertion in this file. ----
    // Last Cost Price must surface as the exact fixed-scale-4 STRING "12.5000" (row 1)
    // and "8.0000" (row 2): quoted, four decimals, trailing zeros preserved. A test
    // that only checked numeric equality (12.5m) would MISS the very bug this artifact
    // exists to catch. Assert on the JSON token kind so a number would fail, and pin
    // the exact serialised text.
    [Fact]
    public void LastCostPrice_Is_Exact_FixedScale4_JsonString()
    {
        var service = new GetStockHoldingUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute()));

        var row1 = doc.RootElement[0].GetProperty("Last Cost Price");
        var row2 = doc.RootElement[1].GetProperty("Last Cost Price");

        // Must be a JSON string, not a number.
        Assert.Equal(JsonValueKind.String, row1.ValueKind);
        Assert.Equal(JsonValueKind.String, row2.ValueKind);

        // Exact fixed-scale-4 text, trailing zeros intact.
        Assert.Equal("12.5000", row1.GetString());
        Assert.Equal("8.0000", row2.GetString());
    }

    // The same trap, seen through the gate's canonical form: the quoted, scale-4
    // strings survive and none of the lossy-double forms a float round-trip would
    // produce appear.
    [Fact]
    public void LastCostPrice_Survives_Canonicalisation_As_Quoted_Scale4()
    {
        var service = new GetStockHoldingUpdatesService(_db);
        var canon = Canonicalise(JsonSerializer.Serialize(service.Execute()));

        Assert.Contains("\"12.5000\"", canon);
        Assert.Contains("\"8.0000\"", canon);
        // A double read would render 12.5 / 12.50 / 12.499999… — none may appear.
        Assert.DoesNotContain("\"12.5\"", canon);
        Assert.DoesNotContain("\"12.50\"", canon);
        Assert.DoesNotContain("12.499", canon);
        Assert.DoesNotContain(":12.5", canon); // never an unquoted number token
    }

    // The other half of the type contract: every remaining numeric field is a plain,
    // unquoted JSON integer — NOT a string, NOT a float with a decimal point. A
    // regression that stringified integers (or floated them) fails here.
    [Fact]
    public void Integer_Fields_Are_Unquoted_Whole_Numbers()
    {
        var service = new GetStockHoldingUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute()));

        string[] intFields =
        {
            "Quantity On Hand", "Last Stocktake Quantity", "Reorder Level",
            "Target Stock Level", "WWI Stock Item ID",
        };

        foreach (var row in doc.RootElement.EnumerateArray())
        {
            foreach (var field in intFields)
            {
                var v = row.GetProperty(field);
                Assert.Equal(JsonValueKind.Number, v.ValueKind);
                Assert.True(v.TryGetInt32(out _), $"{field} should be an int32");
                var raw = v.GetRawText();
                Assert.DoesNotContain('.', raw);
                Assert.DoesNotContain('e', raw);
                Assert.DoesNotContain('E', raw);
            }
        }
    }

    private static void AssertSameString(JsonElement golden, JsonElement actual, string key)
    {
        var g = golden.GetProperty(key);
        var a = actual.GetProperty(key);
        Assert.Equal(JsonValueKind.String, g.ValueKind);
        Assert.Equal(JsonValueKind.String, a.ValueKind);
        Assert.Equal(g.GetString(), a.GetString());
    }

    private static void AssertSameInt(JsonElement golden, JsonElement actual, string key)
    {
        var g = golden.GetProperty(key);
        var a = actual.GetProperty(key);
        Assert.Equal(JsonValueKind.Number, g.ValueKind);
        Assert.Equal(JsonValueKind.Number, a.ValueKind);
        Assert.Equal(g.GetInt32(), a.GetInt32());
    }

    // Shell out to corpus/canonicalise.py --ordered: the tests use the gate's real
    // normal form, not a C# reimplementation that could drift from it.
    private string Canonicalise(string json)
    {
        var script = Path.Combine(_repoRoot, "corpus", "canonicalise.py");
        // Resolve the Python launcher the same way the gate scripts do: honour
        // $PYTHON, else the Windows `py` launcher, else `python3` (Linux CI has no
        // `py`). Keeps one test suite green on a dev box and on the ubuntu runner.
        var python = Environment.GetEnvironmentVariable("PYTHON")
                     ?? (OperatingSystem.IsWindows() ? "py" : "python3");
        var psi = new ProcessStartInfo
        {
            FileName = python,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            StandardOutputEncoding = Encoding.UTF8,
        };
        psi.ArgumentList.Add(script);
        psi.ArgumentList.Add("--ordered");

        using var proc = Process.Start(psi)!;
        proc.StandardInput.Write(json);
        proc.StandardInput.Close();
        var outText = proc.StandardOutput.ReadToEnd();
        var errText = proc.StandardError.ReadToEnd();
        proc.WaitForExit();
        Assert.True(proc.ExitCode == 0, $"canonicalise.py failed: {errText}");
        return outText.Trim();
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "corpus", "canonicalise.py")))
                return dir.FullName;
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException("could not locate repo root (corpus/canonicalise.py)");
    }
}
