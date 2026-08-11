using System.Globalization;
using MongoDB.Bson;
using MongoDB.Driver;

namespace SqlToService.Generated;

/// <summary>
/// Converted from the T-SQL stored procedure <c>Integration.GetTransactionUpdates</c>.
///
/// An incremental change-feed: a <c>UNION ALL</c> of a customer-transactions arm and a
/// supplier-transactions arm, each windowed on <c>LastEditedWhen</c> over the half-open
/// interval <c>(@LastCutoff, @NewCutoff]</c> (strictly-greater at the low end,
/// less-than-or-equal at the high end). Both arms project the SAME 17 columns under
/// friendly space-aliases; each arm hard-codes JSON null for the columns that do not
/// apply to it. There is NO ORDER BY (case ordered:false) — the port emits customer
/// rows then supplier rows and the differential canonicaliser sorts before comparing.
///
/// The Mongo seed is flat (one collection per table, ADR-0003):
///   Sales_CustomerTransactions      (_id = CustomerTransactionID)
///   Purchasing_SupplierTransactions (_id = SupplierTransactionID)
///   Sales_Invoices                  (_id = InvoiceID)
/// The customer arm LEFT-joins to Sales_Invoices on ct.InvoiceID == invoice._id, and
/// [WWI Customer ID] = COALESCE(i.CustomerID, ct.CustomerID). See the spec and the
/// decimal-mapping / document-modelling skills for the rules reproduced here.
/// </summary>
public sealed class GetTransactionUpdatesService
{
    private readonly IMongoCollection<BsonDocument> _customerTransactions;
    private readonly IMongoCollection<BsonDocument> _supplierTransactions;
    private readonly IMongoCollection<BsonDocument> _invoices;

    public GetTransactionUpdatesService(IMongoDatabase database)
    {
        // Collection names are the relational table names with the schema dot replaced
        // by "_" (to_mongo.py). Each collection's _id is the declared PK (KEY_MAP).
        _customerTransactions = database.GetCollection<BsonDocument>("Sales_CustomerTransactions");
        _supplierTransactions = database.GetCollection<BsonDocument>("Purchasing_SupplierTransactions");
        _invoices = database.GetCollection<BsonDocument>("Sales_Invoices");
    }

    /// <summary>
    /// Returns the merged change-feed rows for the half-open window
    /// (<paramref name="lastCutoff"/>, <paramref name="newCutoff"/>]. Customer-arm rows
    /// first, then supplier-arm rows (order is not contractual). Empty window -> [].
    /// </summary>
    public IReadOnlyList<object> Execute(DateTime lastCutoff, DateTime newCutoff)
    {
        var rows = new List<object>();
        rows.AddRange(CustomerArm(lastCutoff, newCutoff));
        rows.AddRange(SupplierArm(lastCutoff, newCutoff));
        return rows;
    }

    // Arm 1 — Sales_CustomerTransactions LEFT OUTER JOIN Sales_Invoices.
    private IEnumerable<object> CustomerArm(DateTime lastCutoff, DateTime newCutoff)
    {
        // Load invoices once, keyed by _id (= InvoiceID), for the in-memory LEFT join.
        var invoicesById = _invoices.Find(FilterDefinition<BsonDocument>.Empty).ToList()
            .ToDictionary(d => d["_id"].ToInt32(), d => d);

        var cts = _customerTransactions.Find(FilterDefinition<BsonDocument>.Empty).ToList();

        foreach (var ct in cts)
        {
            // WHERE ct.LastEditedWhen > @LastCutoff AND ct.LastEditedWhen <= @NewCutoff.
            if (!InWindow(ct, lastCutoff, newCutoff))
                continue;

            // LEFT JOIN: keep the transaction even when InvoiceID is null or unmatched;
            // the invoice side simply contributes nothing.
            var invoiceId = AsNullableInt(ct, "InvoiceID");
            BsonDocument? invoice = null;
            if (invoiceId is not null)
                invoicesById.TryGetValue(invoiceId.Value, out invoice);

            // COALESCE(i.CustomerID, ct.CustomerID): prefer the invoice's CustomerID when
            // the join hit, else fall back to ct.CustomerID. Distinct expression from
            // [WWI Bill To Customer ID], which is ALWAYS ct.CustomerID — do not alias.
            var ctCustomerId = AsNullableInt(ct, "CustomerID");
            var invoiceCustomerId = invoice is null ? null : AsNullableInt(invoice, "CustomerID");
            var wwiCustomerId = invoiceCustomerId ?? ctCustomerId;

            yield return new Dictionary<string, object?>
            {
                ["Date Key"] = AsDateOnly(ct, "TransactionDate"),
                ["WWI Customer Transaction ID"] = Id(ct),
                ["WWI Supplier Transaction ID"] = null, // hard NULL (customer arm)
                ["WWI Invoice ID"] = invoiceId,
                ["WWI Purchase Order ID"] = null,       // hard NULL (customer arm)
                ["Supplier Invoice Number"] = null,     // hard NULL (customer arm)
                ["Total Excluding Tax"] = AsDecimalString(ct, "AmountExcludingTax"),
                ["Tax Amount"] = AsDecimalString(ct, "TaxAmount"),
                ["Total Including Tax"] = AsDecimalString(ct, "TransactionAmount"),
                ["Outstanding Balance"] = AsDecimalString(ct, "OutstandingBalance"),
                ["Is Finalized"] = AsBool(ct, "IsFinalized"),
                ["WWI Customer ID"] = wwiCustomerId,
                ["WWI Bill To Customer ID"] = ctCustomerId,
                ["WWI Supplier ID"] = null,             // hard NULL (customer arm)
                ["WWI Transaction Type ID"] = AsNullableInt(ct, "TransactionTypeID"),
                ["WWI Payment Method ID"] = AsNullableInt(ct, "PaymentMethodID"),
                ["Last Modified When"] = AsDateTime(ct, "LastEditedWhen"),
            };
        }
    }

    // Arm 2 — Purchasing_SupplierTransactions, no join.
    private IEnumerable<object> SupplierArm(DateTime lastCutoff, DateTime newCutoff)
    {
        var sts = _supplierTransactions.Find(FilterDefinition<BsonDocument>.Empty).ToList();

        foreach (var st in sts)
        {
            if (!InWindow(st, lastCutoff, newCutoff))
                continue;

            yield return new Dictionary<string, object?>
            {
                ["Date Key"] = AsDateOnly(st, "TransactionDate"),
                ["WWI Customer Transaction ID"] = null, // hard NULL (supplier arm)
                ["WWI Supplier Transaction ID"] = Id(st),
                ["WWI Invoice ID"] = null,              // hard NULL (supplier arm)
                ["WWI Purchase Order ID"] = AsNullableInt(st, "PurchaseOrderID"),
                ["Supplier Invoice Number"] = AsString(st, "SupplierInvoiceNumber"),
                ["Total Excluding Tax"] = AsDecimalString(st, "AmountExcludingTax"),
                ["Tax Amount"] = AsDecimalString(st, "TaxAmount"),
                ["Total Including Tax"] = AsDecimalString(st, "TransactionAmount"),
                ["Outstanding Balance"] = AsDecimalString(st, "OutstandingBalance"),
                ["Is Finalized"] = AsBool(st, "IsFinalized"),
                ["WWI Customer ID"] = null,             // hard NULL (supplier arm)
                ["WWI Bill To Customer ID"] = null,     // hard NULL (supplier arm)
                ["WWI Supplier ID"] = AsNullableInt(st, "SupplierID"),
                ["WWI Transaction Type ID"] = AsNullableInt(st, "TransactionTypeID"),
                ["WWI Payment Method ID"] = AsNullableInt(st, "PaymentMethodID"),
                ["Last Modified When"] = AsDateTime(st, "LastEditedWhen"),
            };
        }
    }

    // Half-open window on LastEditedWhen: > lastCutoff (strict) AND <= newCutoff.
    private static bool InWindow(BsonDocument doc, DateTime lastCutoff, DateTime newCutoff)
    {
        var when = AsDateTimeValue(doc, "LastEditedWhen");
        if (when is null) return false;
        return when.Value > lastCutoff && when.Value <= newCutoff;
    }

    // The transaction id is the collection's _id (KEY_MAP).
    private static int Id(BsonDocument doc) => doc["_id"].ToInt32();

    private static int? AsNullableInt(BsonDocument doc, string field)
    {
        if (!doc.TryGetValue(field, out var v) || v.IsBsonNull) return null;
        return v.ToInt32();
    }

    private static bool? AsBool(BsonDocument doc, string field)
    {
        if (!doc.TryGetValue(field, out var v) || v.IsBsonNull) return null;
        return v.ToBoolean();
    }

    private static string? AsString(BsonDocument doc, string field)
    {
        if (!doc.TryGetValue(field, out var v) || v.IsBsonNull) return null;
        // Trim CHAR(n) padding the same way canonicalise.py does.
        return v.AsString.TrimEnd();
    }

    // Decimal money -> .NET decimal -> fixed-scale-4 InvariantCulture string.
    // NEVER via double: the seed stores these as Decimal128 (to_mongo.py maps floats
    // to {"$numberDecimal":..}), but we read the BsonValue defensively — Decimal128,
    // or an integer type — and convert straight to System.Decimal, so the fixed-scale
    // digits survive. The golden carries quoted, scale-4 strings ("250.0000"); a bare
    // decimal would serialise as an unquoted number and drop trailing zeros, and a
    // double round-trip is the precision mutant the differential exists to catch.
    private static string? AsDecimalString(BsonDocument doc, string field)
    {
        if (!doc.TryGetValue(field, out var v) || v.IsBsonNull) return null;
        decimal value = v.BsonType switch
        {
            BsonType.Decimal128 => Decimal128.ToDecimal(v.AsDecimal128),
            BsonType.Int32 => v.AsInt32,
            BsonType.Int64 => v.AsInt64,
            // Last resort only; the seed never stores money as a BSON double, but if it
            // did we still avoid binary-float drift by formatting the exact digits.
            _ => decimal.Parse(v.ToString()!, NumberStyles.Any, CultureInfo.InvariantCulture),
        };
        return value.ToString("F4", CultureInfo.InvariantCulture);
    }

    // CAST(TransactionDate AS date) -> date-only "yyyy-MM-dd" (no time component).
    private static string? AsDateOnly(BsonDocument doc, string field)
    {
        var dt = AsDateTimeValue(doc, field);
        return dt?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    // LastEditedWhen -> "yyyy-MM-ddTHH:mm:ss" (datetime, no timezone), as the golden shows.
    private static string? AsDateTime(BsonDocument doc, string field)
    {
        var dt = AsDateTimeValue(doc, field);
        return dt?.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
    }

    // Read a BSON date as a naive DateTime. to_mongo.py stored the seed's ISO date
    // strings as BSON dates (UTC); we read the UTC wall-clock so the emitted string
    // matches the golden's timezone-free rendering.
    private static DateTime? AsDateTimeValue(BsonDocument doc, string field)
    {
        if (!doc.TryGetValue(field, out var v) || v.IsBsonNull) return null;
        return v.ToUniversalTime();
    }
}
