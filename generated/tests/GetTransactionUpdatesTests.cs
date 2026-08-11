using System.Diagnostics;
using System.Text;
using System.Text.Json;
using MongoDB.Bson;
using MongoDB.Driver;
using SqlToService.Generated;
using Xunit;

namespace SqlToService.Generated.Tests;

// Unit tests for the converted Integration.GetTransactionUpdates service. Written
// from the SPEC and the GOLDEN, NOT from the implementation's reasoning
// (ADR-0001/0004): each test asserts the service output equals the golden AFTER the
// same canonical form the differential gate uses (corpus/canonicalise.py). This proc
// is captured with ordered:false, so canonicalise is invoked WITHOUT --ordered — row
// order is not contractual and the canonicaliser sorts rows by value before compare.
//
// Beyond the golden match, the contract details canonicalisation could launder are
// pinned directly on the raw serialised output: the four money columns must surface
// as quoted, fixed-scale-4 JSON STRINGS ("250.0000" ...) never floats; the per-arm
// hard NULLs must all be JSON null; the COALESCE i-side vs ct-side fallback and the
// Bill-To-vs-Customer-ID distinction must be exercised on both branches; Date Key is
// date-only; Is Finalized is an unquoted bool; id columns are unquoted numbers.
//
// Requires the Mongo container on :37017. Seeds a fresh, isolated database with the
// flat documents to_mongo.py would emit from relational.json for
// Sales.CustomerTransactions (2 rows), Purchasing.SupplierTransactions (1 row) and
// Sales.Invoices (2 rows): PK -> _id, decimals -> Decimal128 at fixed scale 4
// (NEVER a double), ISO date strings -> BSON UTC dates.
public sealed class GetTransactionUpdatesTests : IDisposable
{
    private readonly string _dbName = "wwi_test_gettransactionupdates";
    private readonly MongoClient _client;
    private readonly IMongoDatabase _db;
    private readonly string _repoRoot;

    public GetTransactionUpdatesTests()
    {
        _client = new MongoClient("mongodb://localhost:37017");
        _client.DropDatabase(_dbName);
        _db = _client.GetDatabase(_dbName);
        _repoRoot = FindRepoRoot();
        Seed();
    }

    public void Dispose() => _client.DropDatabase(_dbName);

    // The flat seed, exactly as to_mongo.py would produce it from relational.json.
    // Money columns are Decimal128 at fixed scale 4 (mirroring the {"$numberDecimal":..}
    // the seed carries); a double here would defeat the precision round-trip these
    // tests exist to exercise. Dates are BSON UTC datetimes; the date-only source
    // columns (TransactionDate) become midnight-UTC just as fromisoformat("2020-01-05")
    // would. Inserted in reverse id order so nothing passes by insertion luck.
    private void Seed()
    {
        _db.GetCollection<BsonDocument>("Sales_CustomerTransactions").InsertMany(new[]
        {
            // CT 2: NULL InvoiceID -> COALESCE fallback to ct.CustomerID=2; not finalized.
            new BsonDocument
            {
                { "_id", 2 },
                { "InvoiceID", BsonNull.Value },
                { "CustomerID", 2 },
                { "TransactionTypeID", 1 },
                { "PaymentMethodID", 4 },
                { "TransactionDate", Utc(2020, 2, 5, 0, 0, 0) },
                { "AmountExcludingTax", Dec("100.0000") },
                { "TaxAmount", Dec("10.0000") },
                { "TransactionAmount", Dec("110.0000") },
                { "OutstandingBalance", Dec("110.0000") },
                { "IsFinalized", false },
                { "LastEditedWhen", Utc(2020, 2, 20, 9, 0, 0) },
            },
            // CT 1: InvoiceID=1 -> LEFT JOIN hits invoice 1 -> COALESCE picks i.CustomerID=1.
            new BsonDocument
            {
                { "_id", 1 },
                { "InvoiceID", 1 },
                { "CustomerID", 1 },
                { "TransactionTypeID", 1 },
                { "PaymentMethodID", BsonNull.Value },
                { "TransactionDate", Utc(2020, 1, 5, 0, 0, 0) },
                { "AmountExcludingTax", Dec("250.0000") },
                { "TaxAmount", Dec("37.5000") },
                { "TransactionAmount", Dec("287.5000") },
                { "OutstandingBalance", Dec("0.0000") },
                { "IsFinalized", true },
                { "LastEditedWhen", Utc(2020, 1, 20, 9, 0, 0) },
            },
        });

        _db.GetCollection<BsonDocument>("Purchasing_SupplierTransactions").InsertMany(new[]
        {
            // ST 1: supplier arm, no join. Carries SupplierInvoiceNumber, SupplierID,
            // PurchaseOrderID; PaymentMethodID is data-driven null.
            new BsonDocument
            {
                { "_id", 1 },
                { "PurchaseOrderID", 1 },
                { "SupplierID", 1 },
                { "SupplierInvoiceNumber", "SI-001" },
                { "TransactionTypeID", 5 },
                { "PaymentMethodID", BsonNull.Value },
                { "TransactionDate", Utc(2020, 1, 8, 0, 0, 0) },
                { "AmountExcludingTax", Dec("500.0000") },
                { "TaxAmount", Dec("50.0000") },
                { "TransactionAmount", Dec("550.0000") },
                { "OutstandingBalance", Dec("0.0000") },
                { "IsFinalized", true },
                { "LastEditedWhen", Utc(2020, 1, 20, 9, 0, 0) },
            },
        });

        _db.GetCollection<BsonDocument>("Sales_Invoices").InsertMany(new[]
        {
            // Invoice 1: CustomerID=1 -> this is what the COALESCE i-side pulls for CT 1.
            new BsonDocument
            {
                { "_id", 1 },
                { "BillToCustomerID", 1 },
                { "ConfirmedDeliveryTime", Utc(2020, 1, 7, 15, 0, 0) },
                { "CustomerID", 1 },
                { "InvoiceDate", Utc(2020, 1, 5, 0, 0, 0) },
                { "LastEditedWhen", Utc(2020, 1, 20, 9, 0, 0) },
                { "SalespersonPersonID", 1 },
            },
            // Invoice 2 exists but no CT references it (CT 2's InvoiceID is null).
            new BsonDocument
            {
                { "_id", 2 },
                { "BillToCustomerID", 1 },
                { "ConfirmedDeliveryTime", BsonNull.Value },
                { "CustomerID", 2 },
                { "InvoiceDate", Utc(2020, 2, 5, 0, 0, 0) },
                { "LastEditedWhen", Utc(2020, 2, 20, 9, 0, 0) },
                { "SalespersonPersonID", 1 },
            },
        });
    }

    private static BsonDecimal128 Dec(string s) => new(Decimal128.Parse(s));

    private static BsonDateTime Utc(int y, int mo, int d, int h, int mi, int s) =>
        new(new DateTime(y, mo, d, h, mi, s, DateTimeKind.Utc));

    // Case params from corpus/cases/Integration.GetTransactionUpdates.json, as UTC to
    // match the seed's UTC datetimes. Keyed by case name so the [Theory] is data-driven.
    private static (DateTime lastCutoff, DateTime newCutoff) WindowFor(string caseName) => caseName switch
    {
        "jan-both-arms" => (U(2020, 1, 1), U(2020, 2, 1)),
        "feb-coalesce-fallback" => (U(2020, 2, 1), U(2020, 3, 1)),
        "both-months" => (U(2020, 1, 1), U(2020, 3, 1)),
        "empty-window" => (U(2019, 1, 1), U(2019, 2, 1)),
        _ => throw new ArgumentOutOfRangeException(nameof(caseName), caseName, "unknown case"),
    };

    private static DateTime U(int y, int mo, int d) => new(y, mo, d, 0, 0, 0, DateTimeKind.Utc);

    // ---- 1. Golden match, canonicalised the same way the gate compares (unordered). ----
    [Theory]
    [InlineData("jan-both-arms")]
    [InlineData("feb-coalesce-fallback")]
    [InlineData("both-months")]
    [InlineData("empty-window")]
    public void Matches_Golden(string caseName)
    {
        var (lastCutoff, newCutoff) = WindowFor(caseName);
        var service = new GetTransactionUpdatesService(_db);
        var actual = service.Execute(lastCutoff, newCutoff);

        var actualCanon = Canonicalise(JsonSerializer.Serialize(actual));
        var goldenPath = Path.Combine(_repoRoot, "corpus", "golden",
            $"Integration.GetTransactionUpdates__{caseName}.json");
        var goldenCanon = Canonicalise(File.ReadAllText(goldenPath));

        Assert.Equal(goldenCanon, actualCanon);
    }

    // ---- 2. Empty window returns [] (not null, not an error). ----
    [Fact]
    public void Empty_Window_Returns_Empty_Array()
    {
        var (lastCutoff, newCutoff) = WindowFor("empty-window");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        Assert.Equal(JsonValueKind.Array, doc.RootElement.ValueKind);
        Assert.Equal(0, doc.RootElement.GetArrayLength());
    }

    // Row counts per window: the half-open window plus UNION-ALL fan-out.
    [Theory]
    [InlineData("jan-both-arms", 2)]
    [InlineData("feb-coalesce-fallback", 1)]
    [InlineData("both-months", 3)]
    public void Returns_Expected_Row_Count(string caseName, int expected)
    {
        var (lastCutoff, newCutoff) = WindowFor(caseName);
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));
        Assert.Equal(expected, doc.RootElement.GetArrayLength());
    }

    // ---- 3. THE COALESCE contract — both branches. ----
    // jan-both-arms: CT 1 has InvoiceID=1 that joins invoice 1 (CustomerID=1), so
    // WWI Customer ID must come from the INVOICE side (i.CustomerID), not merely from
    // ct.CustomerID. In this seed both are 1, so this alone can't prove the i-side, but
    // it pins the value the golden asserts.
    [Fact]
    public void Coalesce_Customer_Id_Comes_From_Invoice_When_Join_Hits()
    {
        var (lastCutoff, newCutoff) = WindowFor("jan-both-arms");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        var ct1 = CustomerRow(doc, transactionId: 1);
        Assert.Equal(1, ct1.GetProperty("WWI Customer ID").GetInt32());
        Assert.Equal(1, ct1.GetProperty("WWI Invoice ID").GetInt32());
    }

    // feb-coalesce-fallback: CT 2 has NULL InvoiceID -> the LEFT join contributes
    // nothing -> COALESCE falls back to ct.CustomerID=2. WWI Invoice ID is null here.
    [Fact]
    public void Coalesce_Customer_Id_Falls_Back_To_Ct_When_No_Invoice()
    {
        var (lastCutoff, newCutoff) = WindowFor("feb-coalesce-fallback");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        var ct2 = CustomerRow(doc, transactionId: 2);
        Assert.Equal(2, ct2.GetProperty("WWI Customer ID").GetInt32());
        Assert.Equal(JsonValueKind.Null, ct2.GetProperty("WWI Invoice ID").ValueKind);
    }

    // ---- 4. Bill-To vs Customer-ID distinction. ----
    // On the customer arm WWI Bill To Customer ID is ALWAYS ct.CustomerID (not the
    // invoice's BillToCustomerID); on the supplier arm it is a hard NULL.
    [Fact]
    public void BillTo_Customer_Id_Is_CtCustomer_On_Customer_Arm_And_Null_On_Supplier_Arm()
    {
        var (lastCutoff, newCutoff) = WindowFor("both-months");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        var ct1 = CustomerRow(doc, transactionId: 1);
        var ct2 = CustomerRow(doc, transactionId: 2);
        var st1 = SupplierRow(doc, transactionId: 1);

        // ct.CustomerID on the customer arm (1 and 2 respectively).
        Assert.Equal(1, ct1.GetProperty("WWI Bill To Customer ID").GetInt32());
        Assert.Equal(2, ct2.GetProperty("WWI Bill To Customer ID").GetInt32());
        // Hard NULL on the supplier arm.
        Assert.Equal(JsonValueKind.Null, st1.GetProperty("WWI Bill To Customer ID").ValueKind);
    }

    // ---- 5. Per-arm hard NULLs (verify both directions). ----
    [Fact]
    public void Customer_Arm_Hard_Nulls_Are_Json_Null()
    {
        var (lastCutoff, newCutoff) = WindowFor("jan-both-arms");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        var ct1 = CustomerRow(doc, transactionId: 1);
        foreach (var key in new[]
        {
            "WWI Supplier Transaction ID", "WWI Purchase Order ID",
            "Supplier Invoice Number", "WWI Supplier ID",
        })
        {
            Assert.Equal(JsonValueKind.Null, ct1.GetProperty(key).ValueKind);
        }
    }

    [Fact]
    public void Supplier_Arm_Hard_Nulls_Are_Json_Null()
    {
        var (lastCutoff, newCutoff) = WindowFor("jan-both-arms");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        var st1 = SupplierRow(doc, transactionId: 1);
        foreach (var key in new[]
        {
            "WWI Customer Transaction ID", "WWI Invoice ID",
            "WWI Customer ID", "WWI Bill To Customer ID",
        })
        {
            Assert.Equal(JsonValueKind.Null, st1.GetProperty(key).ValueKind);
        }

        // The supplier arm's genuine payload survives.
        Assert.Equal("SI-001", st1.GetProperty("Supplier Invoice Number").GetString());
        Assert.Equal(1, st1.GetProperty("WWI Supplier ID").GetInt32());
        Assert.Equal(1, st1.GetProperty("WWI Purchase Order ID").GetInt32());
    }

    // ---- 6. THE DECIMAL TRAP — the highest-value assertion in this file. ----
    // The four money columns must surface as exact, quoted, fixed-scale-4 JSON STRINGS,
    // trailing zeros intact, never unquoted numbers and never routed through a double.
    // Assert on the JSON token kind so a number would fail, and pin the exact text.
    [Fact]
    public void Money_Columns_Are_Exact_FixedScale4_JsonStrings()
    {
        var (lastCutoff, newCutoff) = WindowFor("both-months");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        var ct1 = CustomerRow(doc, transactionId: 1);
        AssertMoney(ct1, "Total Excluding Tax", "250.0000");
        AssertMoney(ct1, "Tax Amount", "37.5000");
        AssertMoney(ct1, "Total Including Tax", "287.5000");
        AssertMoney(ct1, "Outstanding Balance", "0.0000");

        var ct2 = CustomerRow(doc, transactionId: 2);
        AssertMoney(ct2, "Total Excluding Tax", "100.0000");
        AssertMoney(ct2, "Tax Amount", "10.0000");
        AssertMoney(ct2, "Total Including Tax", "110.0000");
        AssertMoney(ct2, "Outstanding Balance", "110.0000");

        var st1 = SupplierRow(doc, transactionId: 1);
        AssertMoney(st1, "Total Excluding Tax", "500.0000");
        AssertMoney(st1, "Tax Amount", "50.0000");
        AssertMoney(st1, "Total Including Tax", "550.0000");
        AssertMoney(st1, "Outstanding Balance", "0.0000");
    }

    // The same trap through the gate's canonical form: the quoted, scale-4 strings
    // survive and none of the lossy-double forms a float round-trip would produce show.
    [Fact]
    public void Money_Survives_Canonicalisation_As_Quoted_Scale4()
    {
        var (lastCutoff, newCutoff) = WindowFor("both-months");
        var service = new GetTransactionUpdatesService(_db);
        var canon = Canonicalise(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        Assert.Contains("\"250.0000\"", canon);
        Assert.Contains("\"37.5000\"", canon);
        Assert.Contains("\"287.5000\"", canon);
        Assert.Contains("\"110.0000\"", canon);
        Assert.Contains("\"550.0000\"", canon);
        // A double read would render 37.5 / 37.50 / 287.49999… — none may appear, and
        // the value must never be an unquoted number token.
        Assert.DoesNotContain("\"37.5\"", canon);
        Assert.DoesNotContain("\"37.50\"", canon);
        Assert.DoesNotContain(":37.5", canon);
        Assert.DoesNotContain(":250.0", canon);
    }

    // ---- 7. Is Finalized is an unquoted bool; id columns are unquoted numbers. ----
    [Fact]
    public void IsFinalized_Is_Bool_And_Ids_Are_Unquoted_Numbers()
    {
        var (lastCutoff, newCutoff) = WindowFor("both-months");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        var ct1 = CustomerRow(doc, transactionId: 1);
        var ct2 = CustomerRow(doc, transactionId: 2);
        var st1 = SupplierRow(doc, transactionId: 1);

        Assert.Equal(JsonValueKind.True, ct1.GetProperty("Is Finalized").ValueKind);
        Assert.Equal(JsonValueKind.False, ct2.GetProperty("Is Finalized").ValueKind);
        Assert.Equal(JsonValueKind.True, st1.GetProperty("Is Finalized").ValueKind);

        // Present integer id columns are unquoted whole numbers.
        AssertUnquotedInt(ct1, "WWI Customer Transaction ID", 1);
        AssertUnquotedInt(ct1, "WWI Transaction Type ID", 1);
        AssertUnquotedInt(ct2, "WWI Payment Method ID", 4);
        AssertUnquotedInt(st1, "WWI Supplier Transaction ID", 1);
        AssertUnquotedInt(st1, "WWI Transaction Type ID", 5);

        // Data-driven null (not a hard-coded arm NULL) stays null.
        Assert.Equal(JsonValueKind.Null, ct1.GetProperty("WWI Payment Method ID").ValueKind);
        Assert.Equal(JsonValueKind.Null, st1.GetProperty("WWI Payment Method ID").ValueKind);
    }

    // ---- 8. Date Key is date-only "yyyy-MM-dd", distinct from Last Modified When. ----
    [Fact]
    public void Date_Key_Is_Date_Only_Not_Datetime()
    {
        var (lastCutoff, newCutoff) = WindowFor("both-months");
        var service = new GetTransactionUpdatesService(_db);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(service.Execute(lastCutoff, newCutoff)));

        var ct1 = CustomerRow(doc, transactionId: 1);
        var ct2 = CustomerRow(doc, transactionId: 2);
        var st1 = SupplierRow(doc, transactionId: 1);

        Assert.Equal("2020-01-05", ct1.GetProperty("Date Key").GetString());
        Assert.Equal("2020-02-05", ct2.GetProperty("Date Key").GetString());
        Assert.Equal("2020-01-08", st1.GetProperty("Date Key").GetString());

        // Date Key carries no time component; Last Modified When does (and differs).
        Assert.DoesNotContain("T", ct1.GetProperty("Date Key").GetString()!);
        Assert.Equal("2020-01-20T09:00:00", ct1.GetProperty("Last Modified When").GetString());
    }

    // ---- helpers ----

    private static void AssertMoney(JsonElement row, string key, string expected)
    {
        var v = row.GetProperty(key);
        Assert.Equal(JsonValueKind.String, v.ValueKind); // quoted, never a number
        Assert.Equal(expected, v.GetString());
    }

    private static void AssertUnquotedInt(JsonElement row, string key, int expected)
    {
        var v = row.GetProperty(key);
        Assert.Equal(JsonValueKind.Number, v.ValueKind);
        Assert.Equal(expected, v.GetInt32());
        var raw = v.GetRawText();
        Assert.DoesNotContain('.', raw);
        Assert.DoesNotContain('"', raw);
    }

    // Row order is not contractual (ordered:false), so locate rows by identity: the
    // customer arm carries WWI Customer Transaction ID, the supplier arm carries
    // WWI Supplier Transaction ID (each non-null only on its own arm).
    private static JsonElement CustomerRow(JsonDocument doc, int transactionId) =>
        FindRow(doc, "WWI Customer Transaction ID", transactionId);

    private static JsonElement SupplierRow(JsonDocument doc, int transactionId) =>
        FindRow(doc, "WWI Supplier Transaction ID", transactionId);

    private static JsonElement FindRow(JsonDocument doc, string idKey, int idValue)
    {
        foreach (var row in doc.RootElement.EnumerateArray())
        {
            var prop = row.GetProperty(idKey);
            if (prop.ValueKind == JsonValueKind.Number && prop.GetInt32() == idValue)
                return row;
        }
        throw new Xunit.Sdk.XunitException($"no row with {idKey}={idValue} in output");
    }

    // Shell out to corpus/canonicalise.py WITHOUT --ordered (this proc is ordered:false):
    // the tests use the gate's real normal form, not a C# reimplementation that could drift.
    private string Canonicalise(string json)
    {
        var script = Path.Combine(_repoRoot, "corpus", "canonicalise.py");
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
        // NOTE: no --ordered here — the case sets ordered:false, so the canonicaliser
        // sorts rows by value before comparison, matching how the differential gate runs.

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
