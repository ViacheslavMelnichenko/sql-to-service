#!/usr/bin/env python3
"""Unit tests for the two PURE deterministic tools: canonicalise.py and
to_mongo.py. These carry the trust: if canonicalisation isn't stable, the
differential is meaningless; if to_mongo isn't a pure function of its input, the
Mongo seed stops being the same data as the relational seed (ADR-0003).

Stdlib unittest only — runs in the tools container with no pip install:
    docker compose run --rm tools python -m unittest discover -s corpus/tests -v
"""
import importlib.util
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.dirname(HERE)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


canon = _load("canonicalise", os.path.join(CORPUS, "canonicalise.py"))
tomongo = _load("to_mongo", os.path.join(CORPUS, "seed", "to_mongo.py"))


class TestCanonicalise(unittest.TestCase):
    def test_row_order_irrelevant_when_unordered(self):
        a = [{"id": 1}, {"id": 2}, {"id": 3}]
        b = [{"id": 3}, {"id": 1}, {"id": 2}]
        self.assertEqual(canon.canonicalise(a, scale=4, ordered=False),
                         canon.canonicalise(b, scale=4, ordered=False))

    def test_row_order_preserved_when_ordered(self):
        a = [{"id": 1}, {"id": 2}]
        b = [{"id": 2}, {"id": 1}]
        self.assertNotEqual(canon.canonicalise(a, scale=4, ordered=True),
                            canon.canonicalise(b, scale=4, ordered=True))

    def test_key_order_irrelevant(self):
        a = [{"a": 1, "b": 2}]
        b = [{"b": 2, "a": 1}]
        self.assertEqual(canon.canonicalise(a, scale=4, ordered=True),
                         canon.canonicalise(b, scale=4, ordered=True))

    def test_decimal_fixed_scale_string_not_float(self):
        # 10.1 and 10.10 and "10.1000" must all canonicalise identically, as a
        # string — never a float. This is the precision-bug guard.
        out = canon.canonicalise([{"amt": "10.1"}], scale=4, ordered=True)
        self.assertEqual(out[0]["amt"], "10.1000")
        self.assertIsInstance(out[0]["amt"], str)
        same = canon.canonicalise([{"amt": "10.10000"}], scale=4, ordered=True)
        self.assertEqual(out, same)

    def test_trailing_whitespace_stripped(self):
        # CHAR(n) padding must not create a false difference.
        out = canon.canonicalise([{"code": "AB   "}], scale=4, ordered=True)
        self.assertEqual(out[0]["code"], "AB")

    def test_null_and_bool_preserved(self):
        out = canon.canonicalise([{"x": None, "y": True}], scale=4, ordered=True)
        self.assertIsNone(out[0]["x"])
        self.assertIs(out[0]["y"], True)

    def test_integers_stay_integers(self):
        out = canon.canonicalise([{"n": 42}], scale=4, ordered=True)
        self.assertEqual(out[0]["n"], 42)
        self.assertIsInstance(out[0]["n"], int)

    def test_idempotent(self):
        once = canon.canonicalise([{"amt": "3.5", "code": "X  "}], scale=4, ordered=False)
        twice = canon.canonicalise(once, scale=4, ordered=False)
        self.assertEqual(once, twice)


class TestToMongoPurity(unittest.TestCase):
    def test_deterministic_same_input_same_output(self):
        seed = {"Sales.Orders": [{"OrderID": 1, "Total": "10.5"}]}
        self.assertEqual(tomongo.transform(seed), tomongo.transform(seed))

    def test_key_becomes_id(self):
        seed = {"Sales.Orders": [{"OrderID": 7, "CustomerID": 3}]}
        out = tomongo.transform(seed)
        doc = out["Sales_Orders"][0]
        self.assertEqual(doc["_id"], 7)
        self.assertNotIn("OrderID", doc)
        self.assertEqual(doc["CustomerID"], 3)

    def test_no_declared_key_keeps_all_columns(self):
        seed = {"Some.Unmapped": [{"A": 1, "B": 2}]}
        out = tomongo.transform(seed)
        doc = out["Some_Unmapped"][0]
        self.assertNotIn("_id", doc)
        self.assertEqual(doc, {"A": 1, "B": 2})

    def test_decimal_to_decimal128_never_float(self):
        seed = {"Sales.Orders": [{"OrderID": 1, "Total": "19.99"}]}
        out = tomongo.transform(seed)["Sales_Orders"][0]
        self.assertEqual(out["Total"], {"$numberDecimal": "19.9900"})

    def test_collection_name_reversible(self):
        self.assertEqual(tomongo.collection_name("Sales.Orders"), "Sales_Orders")
        self.assertEqual(tomongo.collection_name("Sales.Orders").replace("_", ".", 1),
                         "Sales.Orders")

    def test_iso_date_wrapped(self):
        out = tomongo.map_value("2016-05-31")
        self.assertEqual(out, {"$date": "2016-05-31"})

    def test_intlike_string_becomes_int(self):
        self.assertEqual(tomongo.map_value("42"), 42)

    def test_column_names_preserved_verbatim(self):
        seed = {"X.Y": [{"WeirdColName": 1}]}
        out = tomongo.transform(seed)["X_Y"][0]
        self.assertIn("WeirdColName", out)

    def test_flat_no_embedding(self):
        # Two tables stay two collections — no join, no embedding.
        seed = {"Sales.Orders": [{"OrderID": 1}], "Sales.OrderLines": [{"OrderLineID": 1}]}
        out = tomongo.transform(seed)
        self.assertEqual(set(out), {"Sales_Orders", "Sales_OrderLines"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
