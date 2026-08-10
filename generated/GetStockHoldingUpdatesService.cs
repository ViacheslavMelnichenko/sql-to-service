using MongoDB.Bson;
using MongoDB.Driver;

namespace SqlToService.Generated;

/// <summary>
/// Converted from the T-SQL stored procedure <c>Integration.GetStockHoldingUpdates</c>.
///
/// The original is the simplest shape in the corpus: a zero-parameter, single
/// result-set projection of Warehouse.StockItemHoldings, aliased to friendly
/// column names and ordered by StockItemID. No joins, no filter, no pagination —
/// which is exactly why it earns its place as the SECOND conversion: it isolates
/// the one mechanism the showcase proc could not exercise, the
/// <c>decimal(18,2) → Decimal128 → JSON</c> round-trip on <c>LastCostPrice</c>
/// (the precision thesis of the whole artifact — see the <c>decimal-mapping</c>
/// skill and ADR-0006).
///
/// The Mongo seed is flat (one collection per table, ADR-0003), so this service
/// reads the single collection, projects the seven output columns under their
/// SQL aliases, and orders by the key. The result is the tabular array the
/// original produced; the differential canonicalises both sides before comparing.
/// </summary>
public sealed class GetStockHoldingUpdatesService
{
    private readonly IMongoCollection<BsonDocument> _holdings;

    public GetStockHoldingUpdatesService(IMongoDatabase database)
    {
        // Warehouse.StockItemHoldings -> "Warehouse_StockItemHoldings" (to_mongo.py:
        // schema dot replaced by "_"). StockItemID is the _id (to_mongo KEY_MAP).
        _holdings = database.GetCollection<BsonDocument>("Warehouse_StockItemHoldings");
    }

    /// <summary>
    /// Returns every stock holding as the flat result set the original SELECT
    /// produced, ordered by StockItemID (the proc's ORDER BY). Zero parameters:
    /// the whole table, every time.
    /// </summary>
    public IReadOnlyList<object> Execute()
    {
        var holdings = _holdings.Find(FilterDefinition<BsonDocument>.Empty).ToList();

        return holdings
            // ORDER BY sih.StockItemID — the key is the _id. Numeric order, so a
            // string compare would misorder 2 vs 10; sort on the int value.
            .OrderBy(StockItemId)
            .Select(h => (object)new Dictionary<string, object?>
            {
                // Column order is irrelevant (canonicalise sorts keys); the ALIASES
                // must match the original's SELECT list exactly.
                ["Quantity On Hand"] = AsInt(h, "QuantityOnHand"),
                ["Bin Location"] = AsString(h, "BinLocation"),
                ["Last Stocktake Quantity"] = AsInt(h, "LastStocktakeQuantity"),
                // decimal(18,2), stored as Decimal128 by to_mongo.py. Read it AS a
                // .NET decimal — never a double — so the fixed-scale digits survive
                // to the comparison. Emitting via double is the precision mutant the
                // mutation check injects (corpus/mutations/*.json).
                ["Last Cost Price"] = AsDecimal(h, "LastCostPrice"),
                ["Reorder Level"] = AsInt(h, "ReorderLevel"),
                ["Target Stock Level"] = AsInt(h, "TargetStockLevel"),
                ["WWI Stock Item ID"] = StockItemId(h),
            })
            .ToList();
    }

    // StockItemID is the _id in the Warehouse_StockItemHoldings collection.
    private static int StockItemId(BsonDocument h) => h["_id"].ToInt32();

    private static int AsInt(BsonDocument doc, string field) => doc[field].ToInt32();

    // Decimal128 -> .NET decimal, preserving scale. Not via double: a double cannot
    // represent every decimal exactly, and that lossy conversion is exactly the bug
    // the differential exists to catch (the precision mutant swaps this line for a
    // double round-trip; mutation-check.sh anchors on it).
    private static decimal AsDecimal(BsonDocument doc, string field) =>
        Decimal128.ToDecimal(doc[field].AsDecimal128);

    private static string? AsString(BsonDocument doc, string field)
    {
        if (!doc.TryGetValue(field, out var v) || v.IsBsonNull) return null;
        // Trim CHAR(n) padding the same way canonicalise.py does, so the value
        // matches golden after canonicalisation.
        return v.AsString.TrimEnd();
    }
}
