using System.Diagnostics;
using System.Text;
using System.Text.Json;
using MongoDB.Bson;
using MongoDB.Driver;
using SqlToService.Generated;
using Xunit;

namespace SqlToService.Generated.Tests;

// Unit tests for the converted SearchForCustomers service. Written from the spec
// and golden, NOT from the implementation's reasoning (ADR-0001/0004): each test
// asserts the service output equals that case's golden AFTER the same canonical
// form the differential gate uses (corpus/canonicalise.py --ordered). If the code
// and the golden disagree, the test asserts the golden and is meant to fail.
//
// Requires the Mongo container on :37017 (docker-compose). Each test seeds a fresh,
// isolated database with the flat documents to_mongo.py would emit for the three
// tables this proc reads, so the tests are deterministic and self-contained.
public sealed class SearchForCustomersTests : IDisposable
{
    private readonly string _dbName = "wwi_test_searchforcustomers";
    private readonly MongoClient _client;
    private readonly IMongoDatabase _db;
    private readonly string _repoRoot;

    public SearchForCustomersTests()
    {
        _client = new MongoClient("mongodb://localhost:37017");
        _client.DropDatabase(_dbName);
        _db = _client.GetDatabase(_dbName);
        _repoRoot = FindRepoRoot();
        Seed();
    }

    public void Dispose() => _client.DropDatabase(_dbName);

    // The flat seed, exactly as to_mongo.py would produce it from relational.sql:
    // CustomerID/CityID/PersonID become _id; NULL contact stays null.
    private void Seed()
    {
        _db.GetCollection<BsonDocument>("Application_Cities").InsertMany(new[]
        {
            new BsonDocument { { "_id", 1 }, { "CityName", "Seattle" } },
            new BsonDocument { { "_id", 2 }, { "CityName", "Portland" } },
            new BsonDocument { { "_id", 3 }, { "CityName", "Boston" } },
        });

        _db.GetCollection<BsonDocument>("Application_People").InsertMany(new[]
        {
            Person(3, "Cara Customer", "Cara"),
            Person(1, "Amy Salesperson", "Amy"),
            Person(2, "Ben Employee", "Ben"),
        });

        _db.GetCollection<BsonDocument>("Sales_Customers").InsertMany(new[]
        {
            new BsonDocument
            {
                { "_id", 1 }, { "CustomerName", "Tailspin Toys (Head)" },
                { "DeliveryCityID", 1 }, { "PhoneNumber", "555-0100" },
                { "FaxNumber", "555-0101" }, { "PrimaryContactPersonID", 3 },
            },
            new BsonDocument
            {
                { "_id", 2 }, { "CustomerName", "Wingtip Toys" },
                { "DeliveryCityID", 2 }, { "PhoneNumber", "555-0200" },
                { "FaxNumber", "555-0201" }, { "PrimaryContactPersonID", BsonNull.Value },
            },
        });
    }

    private static BsonDocument Person(int id, string full, string preferred) =>
        new() { { "_id", id }, { "FullName", full }, { "PreferredName", preferred } };

    [Theory]
    [InlineData("toys-both", "Toys", 100)]
    [InlineData("contact-name-match", "Cara", 100)]
    [InlineData("null-contact-name-match", "Wingtip", 100)]
    [InlineData("no-match-empty", "zzz", 100)]
    [InlineData("top-1-pagination", "Toys", 1)]
    public void Matches_Golden(string caseName, string searchText, int maxRows)
    {
        var service = new SearchForCustomersService(_db);
        var actual = service.Execute(searchText, maxRows);

        var actualJson = JsonSerializer.Serialize(actual);
        var goldenPath = Path.Combine(_repoRoot, "corpus", "golden",
            $"Website.SearchForCustomers__{caseName}.json");
        var goldenJson = File.ReadAllText(goldenPath);

        // Canonicalise BOTH sides with the gate's own definition of "same output".
        var actualCanon = Canonicalise(actualJson);
        var goldenCanon = Canonicalise(goldenJson);

        Assert.Equal(goldenCanon, actualCanon);
    }

    [Fact]
    public void Null_Contact_Emits_Empty_Object_Not_Nulls()
    {
        // The single most likely miss: a missed LEFT join must emit "p":[{}], not
        // an omitted key, not [], not nulls. Pin it directly, before canonicalising.
        var service = new SearchForCustomersService(_db);
        var actual = service.Execute("Wingtip", 100);
        var json = JsonSerializer.Serialize(actual);
        using var doc = JsonDocument.Parse(json);

        var customer = doc.RootElement[0];
        var p = customer.GetProperty("ct")[0].GetProperty("p");
        Assert.Equal(JsonValueKind.Array, p.ValueKind);
        Assert.Equal(1, p.GetArrayLength());
        Assert.Equal(0, p[0].EnumerateObject().Count()); // exactly {} — no keys
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
