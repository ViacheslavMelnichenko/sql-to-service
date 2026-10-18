#!/usr/bin/env python3
"""Unit tests for corpus/extract-features.py — the AST feature extractor.

This tool is OBSERVABILITY, not an oracle (ADR-0008): it has no authority over
correctness, so these tests guard its *honesty*, not a verdict. They prove the
facts it reports are the facts that are there — INNER vs LEFT, TOP-after-ORDER,
FOR JSON shape, schema-grounded decimal (and that a CAST AS INT is NOT decimal),
LIKE/CONCAT, params — and that re-running is byte-identical (the determinism the
demo and gates/features-check.sh rely on).

Unlike the other corpus tools, the extractor needs sqlglot. When sqlglot is
absent these tests SKIP cleanly rather than fail — the correctness gate never
needs them (it is stdlib-only); only card/demo regeneration does.

    python -m unittest discover -s corpus/tests -v
"""
import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures")

# Load the hyphenated module by path. The module raises SystemExit(2) at import
# time if sqlglot is missing — catch that and skip the whole suite cleanly.
ef = None
_load_error = None
try:
    spec = importlib.util.spec_from_file_location(
        "extract_features", os.path.join(CORPUS, "extract-features.py"))
    ef = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ef)
    from sqlglot import exp  # noqa: E402  (only valid once ef imported cleanly)
except SystemExit as e:  # import guard fired: sqlglot not installed
    _load_error = f"sqlglot unavailable (SystemExit {e.code})"
except Exception as e:  # pragma: no cover - any other import failure
    _load_error = f"{type(e).__name__}: {e}"


@unittest.skipIf(ef is None, f"extract-features.py not importable: {_load_error}")
class TestExtractFeatures(unittest.TestCase):
    # A tiny schema: only decimal-bearing columns are ever recorded (missing key
    # means "unknown", never "not decimal").
    @classmethod
    def setUpClass(cls):
        cls.schema = {
            ("S.Orders", "Total"): exp.DataType.Type.DECIMAL,
            ("S.Orders", "Tax"): exp.DataType.Type.MONEY,
        }

    def _kinds(self, card):
        return [f["kind"] for f in card["features"]]

    def _of_kind(self, card, kind):
        return [f for f in card["features"] if f["kind"] == kind]

    # --- RETURN strip -------------------------------------------------------
    def test_return_stmt_stripped_does_not_degrade(self):
        sql = ("CREATE PROCEDURE S.P AS BEGIN "
               "SELECT a FROM S.T; RETURN 0; END;")
        card = ef.extract("S.P", sql, {})
        self.assertEqual(card["parse_status"], "ok")

    # --- join classification + dedup ---------------------------------------
    def test_inner_vs_left_join(self):
        sql = ("SELECT o.id FROM S.Orders o "
               "INNER JOIN S.Customers c ON c.id = o.cid "
               "LEFT JOIN S.People p ON p.id = o.pid")
        card = ef.extract("S.P", sql, {})
        kinds = self._kinds(card)
        self.assertIn("join.inner", kinds)
        self.assertIn("join.left", kinds)

    def test_right_and_full_join_classed_as_row_kept(self):
        sql = ("SELECT o.id FROM S.Orders o "
               "RIGHT JOIN S.Customers c ON c.id = o.cid")
        card = ef.extract("S.P", sql, {})
        self.assertIn("join.left", self._kinds(card))
        self.assertNotIn("join.inner", self._kinds(card))

    def test_join_deduped(self):
        # Two SELECTs with the identical join must yield one join feature.
        sql = ("SELECT o.id FROM S.Orders o INNER JOIN S.Customers c ON c.id=o.cid "
               "UNION ALL "
               "SELECT o.id FROM S.Orders o INNER JOIN S.Customers c ON c.id=o.cid")
        card = ef.extract("S.P", sql, {})
        self.assertEqual(len(self._of_kind(card, "join.inner")), 1)

    # --- TOP + ORDER -------------------------------------------------------
    def test_top_after_order_detected(self):
        sql = "SELECT TOP(10) a FROM S.T ORDER BY a"
        card = ef.extract("S.P", sql, {})
        self.assertEqual(len(self._of_kind(card, "top_order")), 1)

    def test_top_without_order_not_flagged(self):
        sql = "SELECT TOP(10) a FROM S.T"
        card = ef.extract("S.P", sql, {})
        self.assertEqual(self._of_kind(card, "top_order"), [])

    # --- decimal resolution via schema -------------------------------------
    def test_plain_decimal_column_resolved(self):
        sql = "SELECT o.Total FROM S.Orders o"
        card = ef.extract("S.P", sql, self.schema)
        decs = self._of_kind(card, "decimal_column")
        self.assertEqual(len(decs), 1)
        self.assertTrue(decs[0]["resolved"])
        self.assertIn("S.Orders.Total", decs[0]["detail"])

    def test_money_column_resolved(self):
        sql = "SELECT o.Tax FROM S.Orders o"
        card = ef.extract("S.P", sql, self.schema)
        self.assertEqual(len(self._of_kind(card, "decimal_column")), 1)

    def test_non_decimal_column_not_flagged(self):
        sql = "SELECT o.OrderDate FROM S.Orders o"
        card = ef.extract("S.P", sql, self.schema)
        self.assertEqual(self._of_kind(card, "decimal_column"), [])

    def test_cast_to_int_is_not_decimal(self):
        # The money column exists, but CAST AS INT overrides — must NOT be decimal.
        sql = "SELECT CAST(o.Total AS INT) AS n FROM S.Orders o"
        card = ef.extract("S.P", sql, self.schema)
        self.assertEqual(self._of_kind(card, "decimal_column"), [])

    def test_cast_to_decimal_is_decimal(self):
        sql = "SELECT CAST(o.OrderDate AS DECIMAL(18,2)) AS d FROM S.Orders o"
        card = ef.extract("S.P", sql, self.schema)
        decs = self._of_kind(card, "decimal_column")
        self.assertEqual(len(decs), 1)
        self.assertTrue(decs[0]["resolved"])

    # --- FOR JSON ----------------------------------------------------------
    def test_for_json_with_root(self):
        sql = "SELECT a FROM S.T FOR JSON AUTO, ROOT('Things')"
        card = ef.extract("S.P", sql, {})
        fj = self._of_kind(card, "for_json")
        self.assertEqual(len(fj), 1)
        self.assertIn("ROOT('Things')", fj[0]["detail"])
        self.assertEqual(card["output_shape"], "for-json")

    def test_no_for_json_is_rowset(self):
        sql = "SELECT a FROM S.T"
        card = ef.extract("S.P", sql, {})
        self.assertEqual(card["output_shape"], "rowset")
        self.assertEqual(self._of_kind(card, "for_json"), [])

    # --- LIKE/CONCAT, set_op, params ---------------------------------------
    def test_like_concat_detected(self):
        sql = "SELECT a FROM S.T WHERE CONCAT(a, b) LIKE '%x%'"
        card = ef.extract("S.P", sql, {})
        self.assertEqual(len(self._of_kind(card, "like_concat")), 1)

    def test_union_all_set_op(self):
        sql = "SELECT a FROM S.T UNION ALL SELECT a FROM S.U"
        card = ef.extract("S.P", sql, {})
        self.assertEqual(len(self._of_kind(card, "set_op")), 1)

    def test_params_extracted(self):
        sql = ("CREATE PROCEDURE S.P @SearchText NVARCHAR(100), @MaxRows INT "
               "AS BEGIN SELECT 1 AS a END;")
        card = ef.extract("S.P", sql, {})
        names = [p["name"] for p in card["params"]]
        self.assertEqual(names, ["@SearchText", "@MaxRows"])
        self.assertEqual(card["params"][0]["type"], "NVARCHAR(100)")

    # --- degraded parse (cursor) -------------------------------------------
    def test_cursor_degrades_but_detects_temporal(self):
        sql = ("CREATE PROCEDURE S.P AS BEGIN "
               "DECLARE c CURSOR FOR SELECT a FROM S.T_Archive; "
               "SELECT a FROM Sales.Customers_Archive; END;")
        card = ef.extract("S.P", sql, {})
        self.assertEqual(card["parse_status"], "degraded")
        self.assertTrue(self._of_kind(card, "temporal"))

    # --- determinism -------------------------------------------------------
    def test_extract_is_deterministic(self):
        sql = ("SELECT o.Total FROM S.Orders o "
               "INNER JOIN S.Customers c ON c.id=o.cid ORDER BY o.Total")
        a = ef.extract("S.P", sql, self.schema)
        b = ef.extract("S.P", sql, self.schema)
        self.assertEqual(a, b)
        self.assertEqual(ef._dumps(a), ef._dumps(b))

    def test_dumps_sorted_keys_trailing_newline(self):
        out = ef._dumps({"b": 1, "a": 2})
        self.assertTrue(out.endswith("\n"))
        self.assertLess(out.index('"a"'), out.index('"b"'))

    # --- mechanical fixture check (acceptance criterion 2) -----------------
    def test_matches_committed_fixture(self):
        """Regenerate the committed fixture card and compare byte-for-byte.
        This is the mechanical (not eyeball) guarantee that a change to the
        extractor that shifts any reported fact is caught by CI."""
        sql = open(os.path.join(FIXTURES, "sample_proc.sql"), encoding="utf-8").read()
        schema = {("Sales.Orders", "Total"): exp.DataType.Type.DECIMAL}
        card = ef.extract("Sales.SampleSearch", sql, schema)
        expected = json.load(
            open(os.path.join(FIXTURES, "sample_proc.expected.json"), encoding="utf-8"))
        self.assertEqual(
            card, expected,
            "extractor output drifted from committed fixture — if intended, "
            "regenerate corpus/tests/fixtures/sample_proc.expected.json")


if __name__ == "__main__":
    unittest.main(verbosity=2)
