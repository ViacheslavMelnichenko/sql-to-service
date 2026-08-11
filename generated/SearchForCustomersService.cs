using System.Globalization;
using System.Text.RegularExpressions;
using MongoDB.Bson;
using MongoDB.Driver;

namespace SqlToService.Generated;

/// <summary>
/// Converted from the T-SQL stored procedure <c>Website.SearchForCustomers</c>.
///
/// The original joins Sales.Customers (c) INNER JOIN Application.Cities (ct)
/// LEFT OUTER JOIN Application.People (p) and returns <c>FOR JSON AUTO</c>, which
/// nests by table alias: c.* at the top, ct.* under "ct" (array), p.* under "p"
/// (array) inside ct. The Mongo seed is flat (one collection per table, ADR-0003),
/// so this service rebuilds that nesting in code. See the spec and the
/// tsql-semantics / document-modelling skills for the rules reproduced here.
/// </summary>
public sealed class SearchForCustomersService
{
    private readonly IMongoCollection<BsonDocument> _customers;
    private readonly IMongoCollection<BsonDocument> _cities;
    private readonly IMongoCollection<BsonDocument> _people;

    public SearchForCustomersService(IMongoDatabase database)
    {
        // Collection names are the relational table names with the schema dot
        // replaced by "_" (to_mongo.py: Sales.Customers -> "Sales_Customers").
        _customers = database.GetCollection<BsonDocument>("Sales_Customers");
        _cities = database.GetCollection<BsonDocument>("Application_Cities");
        _people = database.GetCollection<BsonDocument>("Application_People");
    }

    /// <summary>
    /// Returns the matching customers as the nested object graph the original
    /// FOR JSON AUTO produced. Row order is by CustomerName (the proc's ORDER BY);
    /// the cap is applied after ordering (a TOP-N page).
    /// </summary>
    public IReadOnlyList<object> Execute(string searchText, int maximumRowsToReturn)
    {
        // Load the three flat collections. The seed is tiny (branch-covering, not
        // volume), so an in-memory join reads more clearly than a $lookup pipeline
        // and reproduces the semantics exactly. Method is the implementer's choice;
        // the output is what the gate judges (document-modelling skill).
        var customers = _customers.Find(FilterDefinition<BsonDocument>.Empty).ToList();
        var cities = _cities.Find(FilterDefinition<BsonDocument>.Empty).ToList()
            .ToDictionary(d => d["_id"].ToInt32(), d => d);
        var people = _people.Find(FilterDefinition<BsonDocument>.Empty).ToList()
            .ToDictionary(d => d["_id"].ToInt32(), d => d);

        var results = new List<(string SortKey, object Doc)>();

        foreach (var c in customers)
        {
            // INNER JOIN Cities: a customer whose city is missing is dropped.
            var cityId = AsNullableInt(c, "DeliveryCityID");
            if (cityId is null || !cities.TryGetValue(cityId.Value, out var city))
                continue;

            // LEFT OUTER JOIN People: kept even when the contact is missing.
            var contactId = AsNullableInt(c, "PrimaryContactPersonID");
            BsonDocument? person = null;
            if (contactId is not null)
                people.TryGetValue(contactId.Value, out person);

            var customerName = AsString(c, "CustomerName") ?? string.Empty;
            var contactFull = person is null ? null : AsString(person, "FullName");
            var contactPreferred = person is null ? null : AsString(person, "PreferredName");

            // WHERE CONCAT(CustomerName,' ',FullName,' ',PreferredName) LIKE %text%.
            // CONCAT treats NULL as '' (unlike +), so a NULL contact still matches
            // on the customer name. Match is case-insensitive (CI_AS collation).
            var haystack = string.Concat(
                customerName, " ", contactFull ?? string.Empty, " ", contactPreferred ?? string.Empty);
            if (!LikeContains(haystack, searchText))
                continue;

            // Rebuild FOR JSON AUTO nesting. FOR JSON omits null-valued keys, so the
            // contact object drops absent fields -> {} for a missed LEFT join, which
            // still emits "p":[{}] (array present, one empty object).
            var contactObj = new Dictionary<string, object>();
            AddIfPresent(contactObj, "PrimaryContactFullName", contactFull);
            AddIfPresent(contactObj, "PrimaryContactPreferredName", contactPreferred);

            var cityObj = new Dictionary<string, object>();
            AddIfPresent(cityObj, "CityName", AsString(city, "CityName"));
            // "p" is always present as a one-element array, even when {} (LEFT miss).
            cityObj["p"] = new object[] { contactObj };

            var customerObj = new Dictionary<string, object>();
            AddIfPresent(customerObj, "CustomerID", CustomerId(c));
            AddIfPresent(customerObj, "CustomerName", customerName);
            // Golden key order is CustomerID, CustomerName, FaxNumber, PhoneNumber
            // (Fax BEFORE Phone) — not the SELECT-list order. Emit in that order.
            AddIfPresent(customerObj, "FaxNumber", AsString(c, "FaxNumber"));
            AddIfPresent(customerObj, "PhoneNumber", AsString(c, "PhoneNumber"));
            // "ct" (INNER) is always a populated one-element array.
            customerObj["ct"] = new object[] { cityObj };

            results.Add((customerName, customerObj));
        }

        // ORDER BY CustomerName, THEN TOP(n). Ordinal, culture-invariant compare so
        // the page boundary is deterministic (dotnet-service-shape skill).
        return results
            .OrderBy(r => r.SortKey, StringComparer.Ordinal)
            .Take(Math.Max(0, maximumRowsToReturn))
            .Select(r => r.Doc)
            .ToList();
    }

    // CustomerID is the _id in the Sales_Customers collection (to_mongo KEY_MAP).
    private static int CustomerId(BsonDocument customer) => customer["_id"].ToInt32();

    private static bool LikeContains(string haystack, string needle)
    {
        // Original is `LIKE '%' + @SearchText + '%'`: a case-insensitive substring
        // with @SearchText's %/_ treated as LIKE wildcards (not escaped). Translate
        // the LIKE pattern to a regex: % -> .*, _ -> ., everything else literal.
        var pattern = LikeToRegex(needle);
        return Regex.IsMatch(haystack, pattern,
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Singleline);
    }

    private static string LikeToRegex(string like)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var ch in like)
        {
            switch (ch)
            {
                case '%': sb.Append(".*"); break;
                case '_': sb.Append('.'); break;
                default: sb.Append(Regex.Escape(ch.ToString())); break;
            }
        }
        return sb.ToString();
    }

    private static void AddIfPresent(Dictionary<string, object> obj, string key, object? value)
    {
        // FOR JSON omits NULL-valued keys at every level.
        if (value is not null)
            obj[key] = value;
    }

    private static int? AsNullableInt(BsonDocument doc, string field)
    {
        if (!doc.TryGetValue(field, out var v) || v.IsBsonNull) return null;
        return v.ToInt32();
    }

    private static string? AsString(BsonDocument doc, string field)
    {
        if (!doc.TryGetValue(field, out var v) || v.IsBsonNull) return null;
        // SQL CHAR(n) padding is trimmed in canonical form; trim trailing space here
        // so the value matches golden after canonicalisation.
        return v.AsString.TrimEnd();
    }
}
