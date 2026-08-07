#!/usr/bin/env python3
"""Mechanically derive the Mongo seed from the relational seed. PURE FUNCTION.

This is the ADR-0003 keystone. The generated .NET service reads from Mongo; its
output is compared to a golden captured from the ORIGINAL T-SQL reading from SQL
Server. For that comparison to mean anything, the Mongo data must be the SAME data
as the relational seed — not a hand-authored document store that we (consciously or
not) shaped to match what we expect the service to produce. Hand-authoring the
documents would relocate the oracle problem into the target store; a mechanical,
deterministic transform forecloses it.

So this script is a dumb, total, auditable mapping:

    relational tables (rows)  ->  Mongo collections (documents)

with EXACTLY ONE modelling decision, declared in a table map, and no per-row
cleverness. Every rule below is reviewable in one sitting; nothing here "knows"
anything about the procedures being converted.

Input
-----
A single JSON file: the relational seed exported as
    { "<schema.table>": [ {col: value, ...}, ... ], ... }
This is produced from corpus/seed/relational.sql by the export step (Phase 1),
so Mongo and SQL Server are provably fed from one source.

Modelling rules (the whole contract)
------------------------------------
1. One relational table -> one collection. Collection name = table name with the
   schema dot replaced by "_" (WWI uses Sales.Orders -> "Sales_Orders"), so the
   mapping is reversible and no two tables collide.
2. Column names are preserved verbatim as field names. No renaming, no casing
   changes — a rename is a modelling judgement and judgement is what we are
   refusing to smuggle in here.
3. The primary key column (declared per-table in KEY_MAP) becomes Mongo `_id`.
   If a table has no declared key, `_id` is left to Mongo (auto ObjectId) and the
   original columns are all kept — nothing is dropped.
4. Types map by value, deterministically:
     - decimals  -> {"$numberDecimal": "<fixed-scale string>"} (Decimal128).
       NEVER a float. The decimal->Decimal128 round-trip is the exact precision
       bug the artifact exists to catch, so the seed must carry it losslessly.
     - integers  -> plain JSON int (Mongo int32/int64).
     - ISO date strings that came from SQL date/datetime -> {"$date": "<iso>"}.
     - null / bool / string -> as-is.
5. No embedding, no joins, no denormalisation. The relational shape is preserved
   1:1. Document modelling (embedding related rows) is a CONVERSION decision the
   agent may make in the service; the SEED stays flat so it can't pre-bake an
   answer. (See ADR-0003.)

Output
------
Either mongoimport-ready extended-JSON files (one per collection) written to a
directory, or, with --apply, loaded straight into the mongo container.

    to_mongo.py relational.json --out corpus/seed/mongo/
    to_mongo.py relational.json --apply --uri mongodb://localhost:37017/wwi

The transform is identical in both modes — --apply just also inserts.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from decimal import Decimal, InvalidOperation

DECIMAL_SCALE = 4  # match canonicalise.py: WWI money/qty are decimal(18,4)/(18,2)

# The ONE modelling table: which column is the primary key per relational table.
# Declared, not inferred — an inferred key is a guess, and a wrong guess silently
# changes _id. Tables absent here get a Mongo-assigned _id and keep all columns.
# (Filled per the actually-seeded tables in Phase 1; extend as the seed grows.)
KEY_MAP = {
    "Sales_Customers": "CustomerID",
    "Sales_Orders": "OrderID",
    "Sales_OrderLines": "OrderLineID",
    "Sales_Invoices": "InvoiceID",
    "Purchasing_Suppliers": "SupplierID",
    "Warehouse_StockItems": "StockItemID",
    "Warehouse_StockItemHoldings": "StockItemID",
    "Application_People": "PersonID",
    "Application_Cities": "CityID",
    "Application_Countries": "CountryID",
    "Application_StateProvinces": "StateProvinceID",
}

_ISO_DATE = re.compile(
    r"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$"
)


def collection_name(table: str) -> str:
    """`Sales.Orders` -> `Sales_Orders`. Reversible; dot is the only separator."""
    return table.replace(".", "_")


def _is_intlike(s: str) -> bool:
    return bool(re.fullmatch(r"[+-]?\d+", s))


def map_value(value):
    """Deterministic value -> extended-JSON. No context, no column knowledge."""
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        # A float here is already lossy; pin it to Decimal128 at fixed scale so at
        # least the comparison is stable. Upstream should hand us decimals as
        # strings — see the SQL export (FOR JSON emits them as strings).
        return {"$numberDecimal": _fixed(Decimal(str(value)))}
    if isinstance(value, str):
        if _ISO_DATE.match(value):
            return {"$date": value}
        # Numeric-looking string from SQL's JSON: decimal -> Decimal128, big int
        # stays a string only if it would overflow — otherwise plain int.
        if _is_intlike(value):
            return int(value)
        try:
            d = Decimal(value)
            if "." in value or "e" in value.lower():
                return {"$numberDecimal": _fixed(d)}
        except InvalidOperation:
            pass
        return value
    if isinstance(value, list):
        return [map_value(v) for v in value]
    if isinstance(value, dict):
        return {k: map_value(v) for k, v in value.items()}
    return value


def _fixed(d: Decimal) -> str:
    quant = Decimal(1).scaleb(-DECIMAL_SCALE)
    return format(d.quantize(quant), "f")


def map_row(table_coll: str, row: dict) -> dict:
    doc = {}
    key_col = KEY_MAP.get(table_coll)
    for col, val in row.items():
        mapped = map_value(val)
        if key_col is not None and col == key_col:
            doc["_id"] = mapped
        else:
            doc[col] = mapped
    return doc


def transform(seed: dict) -> dict:
    """relational seed dict -> {collection: [documents]}. Total and pure."""
    if not isinstance(seed, dict):
        raise ValueError("relational seed must be an object of table -> rows")
    out = {}
    for table, rows in seed.items():
        coll = collection_name(table)
        if not isinstance(rows, list):
            raise ValueError(f"table {table!r} must map to a list of rows")
        out[coll] = [map_row(coll, r) for r in rows]
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Mechanically derive the Mongo seed from the relational seed.")
    ap.add_argument("relational", help="relational seed JSON (table -> rows)")
    ap.add_argument("--out", help="write one extended-JSON file per collection into this dir")
    ap.add_argument("--apply", action="store_true", help="also insert into Mongo (needs --uri and pymongo)")
    ap.add_argument("--uri", default="mongodb://localhost:37017/wwi", help="Mongo URI for --apply")
    args = ap.parse_args(argv)

    seed = json.loads(open(args.relational, encoding="utf-8").read())
    collections = transform(seed)

    total = sum(len(v) for v in collections.values())
    sys.stderr.write(f"[to_mongo] {len(collections)} collections, {total} documents\n")

    if args.out:
        import os
        os.makedirs(args.out, exist_ok=True)
        for coll, docs in collections.items():
            path = os.path.join(args.out, f"{coll}.json")
            with open(path, "w", encoding="utf-8") as fh:
                # One extended-JSON doc per line: mongoimport --file <this>.
                for doc in docs:
                    fh.write(json.dumps(doc, ensure_ascii=False, sort_keys=True))
                    fh.write("\n")
            sys.stderr.write(f"[to_mongo] wrote {path} ({len(docs)} docs)\n")

    if args.apply:
        try:
            from pymongo import MongoClient
        except ImportError:
            sys.stderr.write("[to_mongo] --apply needs pymongo (pip install pymongo)\n")
            return 2
        client = MongoClient(args.uri)
        db = client.get_default_database()
        for coll, docs in collections.items():
            db[coll].delete_many({})
            if docs:
                db[coll].insert_many([_to_bson(d) for d in docs])
            sys.stderr.write(f"[to_mongo] loaded {coll}: {len(docs)} docs\n")

    if not args.out and not args.apply:
        json.dump(collections, sys.stdout, ensure_ascii=False, sort_keys=True)
        sys.stdout.write("\n")
    return 0


def _to_bson(doc):
    """Extended-JSON dict -> pymongo-native (Decimal128/datetime). Import-local so
    the pure transform above never imports bson."""
    from bson.decimal128 import Decimal128
    from datetime import datetime

    def conv(v):
        if isinstance(v, dict):
            if "$numberDecimal" in v and len(v) == 1:
                return Decimal128(v["$numberDecimal"])
            if "$date" in v and len(v) == 1:
                return datetime.fromisoformat(v["$date"].replace("Z", "+00:00"))
            return {k: conv(x) for k, x in v.items()}
        if isinstance(v, list):
            return [conv(x) for x in v]
        return v

    return conv(doc)


if __name__ == "__main__":
    raise SystemExit(main())
