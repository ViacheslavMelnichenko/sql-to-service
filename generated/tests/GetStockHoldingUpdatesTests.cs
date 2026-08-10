using System.Diagnostics;
using System.Text;
using System.Text.Json;
using MongoDB.Bson;
using MongoDB.Driver;
using SqlToService.Generated;
using Xunit;

namespace SqlToService.Generated.Tests;

// Unit tests for the converted GetStockHoldingUpdates service. Written from the spec
// and golden, NOT from the implementation's reasoning (ADR-0001/0004): each test
// asserts the service output equals the case's golden AFTER the same canonical form
// the differential gate uses (corpus/canonicalise.py --ordered).
//
// This proc's reason for existing in the corpus is the decimal round-trip
// (LastCostPrice decimal(18,2) -> Decimal128 -> JSON), so beyond the golden match
// there is a direct assertion that the money value survives at fixed scale and is
// NOT emitted through a lossy double. That is the precision mutant's target.
//
// Requires the Mongo container on :37017. Seeds a fresh, isolated database with the
// flat documents to_mongo.py would emit for Warehouse.StockItemHoldings.
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

    // The flat seed, exactly as to_mongo.py would produce it: StockItemID -> _id,
    // LastCostPrice decimal -> Decimal128 (never a double), two rows.
    private void Seed()
    {
        _db.GetCollection<BsonDocument>("Warehouse_StockItemHoldings").InsertMany(new[]
        {
            Holding(1, "L-1", qtyOnHand: 100, lastStocktake: 95, lastCost: 12.50m,
                    reorder: 20, target: 200),
            Holding(2, "L-2", qtyOnHand: 50, lastStocktake: 50, lastCost: 8.00m,
                    reorder: 10, target: 100),
        });
    }

    private static BsonDocument Holding(int id, string bin, int qtyOnHand, int lastStocktake,
        decimal lastCost, int reorder, int target) => new()
    {
        { "_id", id },
        { "BinLocation", bin },
        { "QuantityOnHand", qtyOnHand },
        { "LastStocktakeQuantity", lastStocktake },
        // Decimal128 at scale 4, matching to_mongo.py's fixed-scale seed.
        { "LastCostPrice", new BsonDecimal128(lastCost) },
        { "ReorderLevel", reorder },
        { "TargetStockLevel", target },
    };

    [Theory]
    [InlineData("all-holdings")]
    public void Matches_Golden(string caseName)
    {
        var service = new GetStockHoldingUpdatesService(_db);
        var actual = service.Execute();

        var actualJson = JsonSerializer.Serialize(actual);
        var goldenPath = Path.Combine(_repoRoot, "corpus", "golden",
            $"Integration.GetStockHoldingUpdates__{caseName}.json");
        var goldenJson = File.ReadAllText(goldenPath);

        var actualCanon = Canonicalise(actualJson);
        var goldenCanon = Canonicalise(goldenJson);

        Assert.Equal(goldenCanon, actualCanon);
    }

    [Fact]
    public void LastCostPrice_Keeps_Fixed_Scale_Not_A_Lossy_Double()
    {
        // The precision thesis, pinned directly. The first row's LastCostPrice is
        // 12.50; canonicalise renders decimals at scale 4, so golden says "12.5000".
        // A service that read the value through a double could emit 12.5 or
        // 12.499999… — this asserts the exact fixed-scale string survives.
        var service = new GetStockHoldingUpdatesService(_db);
        var actual = service.Execute();
        var json = JsonSerializer.Serialize(actual);
        var canon = Canonicalise(json);

        Assert.Contains("\"12.5000\"", canon);
        Assert.Contains("\"8.0000\"", canon);
        // And never the bare double forms a lossy read would produce.
        Assert.DoesNotContain("\"12.5\"", canon);
        Assert.DoesNotContain("12.499", canon);
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
