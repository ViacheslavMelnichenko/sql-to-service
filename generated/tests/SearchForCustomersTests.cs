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
//
// Seed shape (mechanical, mirrors to_mongo.py — NOT hand-shaped to the answer):
//   * Two golden customers exactly as relational.json -> to_mongo.py produce them:
//     customer 1 (Tailspin Toys, city Seattle, contact 3 Cara) and customer 2
//     (Wingtip Toys, city Portland, PrimaryContactPersonID NULL -> LEFT-join miss).
//   * One EXTRA customer 3 "Ghostville Emporium" whose DeliveryCityID (999) matches
//     no city row. Its name shares no substring with any golden SearchText, so the
//     five golden cases are untouched; it exists only to prove the INNER city join
//     drops a city-less customer even when it would otherwise match (search "Ghost").
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

    // The flat seed, exactly as to_mongo.py would produce it from relational.json:
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
            // City-less customer: DeliveryCityID 999 matches no city row. The INNER
            // join must drop it entirely (search "Ghost" -> []). Name is disjoint
            // from every golden SearchText so no golden case is perturbed.
            new BsonDocument
            {
                { "_id", 3 }, { "CustomerName", "Ghostville Emporium" },
                { "DeliveryCityID", 999 }, { "PhoneNumber", "555-0900" },
                { "FaxNumber", "555-0901" }, { "PrimaryContactPersonID", BsonNull.Value },
            },
        });
    }

    private static BsonDocument Person(int id, string full, string preferred) =>
        new() { { "_id", id }, { "FullName", full }, { "PreferredName", preferred } };

    // ---- Golden-match cases: one per case in corpus/cases, covering each branch ----
    // toys-both       : both customers, ordered Tailspin then Wingtip; c2 -> p:[{}]
    // contact-name-match : "Cara" matches only via the LEFT-joined contact's name
    // null-contact-name-match : "Wingtip" matches c2 (NULL contact) on its own name
    // no-match-empty  : "zzz" -> []
    // top-1-pagination: "Toys" TOP(1) -> Tailspin only (order before limit)
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

        var actualCanon = Canonicalise(JsonSerializer.Serialize(actual));
        var goldenPath = Path.Combine(_repoRoot, "corpus", "golden",
            $"Website.SearchForCustomers__{caseName}.json");
        var goldenCanon = Canonicalise(File.ReadAllText(goldenPath));

        Assert.Equal(goldenCanon, actualCanon);
    }

    [Fact]
    public void Null_Contact_Emits_Empty_Object_Not_Nulls()
    {
        // The single most likely miss: a missed LEFT join must emit "p":[{}], not
        // an omitted key, not [], not nulls. Pin it directly, before canonicalising.
        var service = new SearchForCustomersService(_db);
        var actual = service.Execute("Wingtip", 100);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(actual));

        var customer = doc.RootElement[0];
        var p = customer.GetProperty("ct")[0].GetProperty("p");
        Assert.Equal(JsonValueKind.Array, p.ValueKind);
        Assert.Equal(1, p.GetArrayLength());
        Assert.Empty(p[0].EnumerateObject()); // exactly {} — no keys
    }

    [Fact]
    public void Contact_Present_Nests_Under_Ct_As_One_Element_Array()
    {
        // Nesting depth: p sits INSIDE ct[0] (join order cities-then-people), not at
        // the top level; both ct and p are one-element arrays.
        var service = new SearchForCustomersService(_db);
        var actual = service.Execute("Cara", 100);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(actual));

        var customer = doc.RootElement[0];
        Assert.False(customer.TryGetProperty("p", out _)); // p is NOT top-level
        var ct = customer.GetProperty("ct");
        Assert.Equal(JsonValueKind.Array, ct.ValueKind);
        Assert.Equal(1, ct.GetArrayLength());
        Assert.Equal("Seattle", ct[0].GetProperty("CityName").GetString());

        var p = ct[0].GetProperty("p");
        Assert.Equal(JsonValueKind.Array, p.ValueKind);
        Assert.Equal(1, p.GetArrayLength());
        Assert.Equal("Cara Customer", p[0].GetProperty("PrimaryContactFullName").GetString());
        Assert.Equal("Cara", p[0].GetProperty("PrimaryContactPreferredName").GetString());
    }

    [Fact]
    public void Top_Level_Key_Order_Is_Id_Name_Fax_Phone_Then_Ct()
    {
        // Golden top-level key order is CustomerID, CustomerName, FaxNumber,
        // PhoneNumber (Fax BEFORE Phone — NOT SELECT-list order), then the ct nest.
        var service = new SearchForCustomersService(_db);
        var actual = service.Execute("Tailspin", 100);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(actual));

        var keys = doc.RootElement[0].EnumerateObject().Select(p => p.Name).ToArray();
        Assert.Equal(
            new[] { "CustomerID", "CustomerName", "FaxNumber", "PhoneNumber", "ct" },
            keys);
    }

    [Theory]
    [InlineData("cara")]
    [InlineData("CARA")]
    [InlineData("Cara")]
    public void Match_Is_Case_Insensitive(string searchText)
    {
        // WWI collation is CI_AS: LIKE is case-insensitive. All three spellings of
        // "cara" must return customer 1 only, via the contact-name haystack.
        var service = new SearchForCustomersService(_db);
        var actual = service.Execute(searchText, 100);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(actual));

        Assert.Single(doc.RootElement.EnumerateArray());
        Assert.Equal(1, doc.RootElement[0].GetProperty("CustomerID").GetInt32());
    }

    [Fact]
    public void City_Less_Customer_Is_Dropped_By_Inner_Join()
    {
        // INNER JOIN Cities: customer 3 (DeliveryCityID 999, no such city) WOULD
        // match "Ghost" by name, but must be dropped entirely. Not softened to LEFT.
        var service = new SearchForCustomersService(_db);
        var actual = service.Execute("Ghost", 100);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(actual));

        Assert.Empty(doc.RootElement.EnumerateArray());
    }

    [Fact]
    public void No_Float_Anywhere_Ids_Are_Integer_Tokens()
    {
        // Precision contract: this proc surfaces no decimal/money column, so the only
        // numbers are integer IDs. Pin that CustomerID serialises as an integer token
        // (no decimal point / exponent) so a float regression fails loudly.
        var service = new SearchForCustomersService(_db);
        var actual = service.Execute("Toys", 100);
        var json = JsonSerializer.Serialize(actual);
        using var doc = JsonDocument.Parse(json);

        foreach (var customer in doc.RootElement.EnumerateArray())
        {
            var id = customer.GetProperty("CustomerID");
            Assert.Equal(JsonValueKind.Number, id.ValueKind);
            Assert.True(id.TryGetInt32(out _));
            Assert.DoesNotContain('.', id.GetRawText());
            Assert.DoesNotContain('e', id.GetRawText());
            Assert.DoesNotContain('E', id.GetRawText());
        }
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
