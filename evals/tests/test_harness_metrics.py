#!/usr/bin/env python3
"""Unit tests for the harness's metric collection — the per-attempt split and the
best-effort per-subagent stage attribution (harness.py), plus the aggregator's
roll-up of wall-time and stage breakdown across samples (aggregate.py).

The live path is never exercised here (it costs money and needs a headless agent),
so these tests PROVE THE PARSING LOGIC against synthetic stream-json fixtures — the
same discipline the rest of the repo uses: the risky code is the transcript
attribution, so that is what is pinned. Honest degradation (no fabricated per-stage
numbers when the stream lacks linkage) is asserted explicitly.

Stdlib unittest only:
    python -m unittest discover -s evals/tests -v
"""
import importlib.util
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EVALS = os.path.dirname(HERE)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


harness = _load("harness", os.path.join(EVALS, "harness.py"))
aggregate = _load("aggregate", os.path.join(EVALS, "aggregate.py"))


def _asst(parent_tool_use_id, in_t, out_t, content=None):
    return json.dumps({
        "type": "assistant",
        "parent_tool_use_id": parent_tool_use_id,
        "message": {"usage": {"input_tokens": in_t, "output_tokens": out_t},
                    "content": content or []},
    })


def _task_block(tid, subagent_type):
    return {"type": "tool_use", "id": tid, "name": "Task",
            "input": {"subagent_type": subagent_type, "description": "d", "prompt": "p"}}


def _result(cost, in_t, out_t, turns, session="sess-1"):
    return json.dumps({
        "type": "result", "subtype": "success",
        "session_id": session, "total_cost_usd": cost, "num_turns": turns,
        "usage": {"input_tokens": in_t, "output_tokens": out_t},
        "modelUsage": {"gw": {"canonicalModel": "claude-opus-4-8"}},
    })


class TestStreamTotals(unittest.TestCase):
    def test_meta_comes_from_result_event(self):
        raw = "\n".join([
            json.dumps({"type": "system", "subtype": "init", "session_id": "sess-1"}),
            _asst(None, 100, 50),
            _result(1.25, 3034, 10585, 30),
        ])
        meta, _ = harness.parse_claude_stream(raw)
        self.assertEqual(meta["total_cost_usd"], 1.25)
        self.assertEqual(meta["usage"]["input_tokens"], 3034)
        self.assertEqual(meta["usage"]["output_tokens"], 10585)
        self.assertEqual(meta["num_turns"], 30)
        self.assertEqual(meta["model_snapshot"], "claude-opus-4-8")
        self.assertEqual(meta["session_id"], "sess-1")

    def test_falls_back_to_plain_json_when_no_result_event(self):
        # A single plain-json object (old --output-format json) still yields totals.
        raw = json.dumps({"session_id": "s", "total_cost_usd": 0.5,
                          "usage": {"input_tokens": 10, "output_tokens": 20},
                          "num_turns": 3, "model": "m"})
        meta, breakdown = harness.parse_claude_stream(raw)
        self.assertEqual(meta["total_cost_usd"], 0.5)
        self.assertFalse(breakdown["available"])

    def test_tolerates_leading_noise_lines(self):
        raw = "\n".join([
            "NuGet advisory: something",
            "",
            _result(2.0, 1, 2, 1),
        ])
        meta, _ = harness.parse_claude_stream(raw)
        self.assertEqual(meta["total_cost_usd"], 2.0)


class TestStageAttribution(unittest.TestCase):
    def test_attributes_tokens_to_subagents_by_parent_id(self):
        raw = "\n".join([
            # orchestrator dispatches the analyst, then the implementer
            _asst(None, 10, 5, content=[_task_block("t-analyst", "analyst")]),
            _asst("t-analyst", 200, 300),          # analyst's work
            _asst("t-analyst", 100, 150),          # analyst again
            _asst(None, 8, 4, content=[_task_block("t-impl", "implementer")]),
            _asst("t-impl", 400, 900),             # implementer's work
            _result(3.0, 726, 1363, 12),
        ])
        _, breakdown = harness.parse_claude_stream(raw)
        self.assertTrue(breakdown["available"])
        stages = {s["stage"]: s for s in breakdown["stages"]}
        self.assertIn("analyst", stages)
        self.assertIn("implementer", stages)
        self.assertIn("orchestrator", stages)
        self.assertEqual(stages["analyst"]["output_tokens"], 450)   # 300 + 150
        self.assertEqual(stages["analyst"]["input_tokens"], 300)    # 200 + 100
        self.assertEqual(stages["analyst"]["messages"], 2)
        self.assertEqual(stages["implementer"]["output_tokens"], 900)
        self.assertEqual(stages["orchestrator"]["output_tokens"], 9)  # 5 + 4
        # orchestrator is listed first, then subagents in dispatch order
        self.assertEqual([s["stage"] for s in breakdown["stages"]][:3],
                         ["orchestrator", "analyst", "implementer"])

    def test_degrades_honestly_without_linkage(self):
        # No Task blocks / no parent_tool_use_id → no fabricated split.
        raw = "\n".join([
            _asst(None, 10, 5),
            _asst(None, 20, 30),
            _result(1.0, 30, 35, 2),
        ])
        _, breakdown = harness.parse_claude_stream(raw)
        self.assertFalse(breakdown["available"])
        self.assertIn("reason", breakdown)
        self.assertNotIn("stages", breakdown)


class TestMergeBreakdowns(unittest.TestCase):
    def test_sums_across_attempts(self):
        a = {"available": True, "stages": [
            {"stage": "analyst", "input_tokens": 100, "output_tokens": 200, "messages": 1}]}
        b = {"available": True, "stages": [
            {"stage": "analyst", "input_tokens": 50, "output_tokens": 60, "messages": 1},
            {"stage": "implementer", "input_tokens": 10, "output_tokens": 20, "messages": 1}]}
        merged = harness._merge_breakdowns([a, b])
        self.assertTrue(merged["available"])
        stages = {s["stage"]: s for s in merged["stages"]}
        self.assertEqual(stages["analyst"]["output_tokens"], 260)
        self.assertEqual(stages["analyst"]["messages"], 2)
        self.assertEqual(stages["implementer"]["output_tokens"], 20)

    def test_unavailable_keeps_reason(self):
        merged = harness._merge_breakdowns([
            {"available": False, "reason": "no linkage"},
            {"available": False, "reason": "also none"},
        ])
        self.assertFalse(merged["available"])
        self.assertEqual(merged["reason"], "no linkage")


class TestAggregateStageAndWall(unittest.TestCase):
    def _proc_rec(self, wall, breakdown, cleared=True):
        return ("s.json", {
            "proc": "P", "outcome": "cleared" if cleared else "failed:differential",
            "cleared_within_cap": cleared, "retries": 0, "num_turns": 10,
            "identity": {"produced_output_sha256": "h", "golden_output_sha256": "h"},
            "cost_usd": 1.0, "tokens": {"input": 5, "output": 7},
            "wall_seconds": wall, "stage_breakdown": breakdown, "source_sha256": "x",
        })

    def test_wall_time_distribution_carried(self):
        bd = {"available": True, "stages": [
            {"stage": "analyst", "input_tokens": 1, "output_tokens": 100, "messages": 1}]}
        recs = [self._proc_rec(100.0, bd), self._proc_rec(140.0, bd)]
        agg = aggregate.aggregate_proc("P", recs)
        self.assertEqual(agg["wall_seconds"]["per_sample"], [100.0, 140.0])
        self.assertEqual(agg["wall_seconds"]["mean"], 120.0)
        self.assertEqual(agg["wall_seconds"]["total"], 240.0)

    def test_stage_breakdown_aggregated_when_available(self):
        bd1 = {"available": True, "stages": [
            {"stage": "analyst", "input_tokens": 1, "output_tokens": 100, "messages": 1}]}
        bd2 = {"available": True, "stages": [
            {"stage": "analyst", "input_tokens": 1, "output_tokens": 200, "messages": 1}]}
        recs = [self._proc_rec(10.0, bd1), self._proc_rec(10.0, bd2)]
        agg = aggregate.aggregate_proc("P", recs)
        sb = agg["stage_breakdown"]
        self.assertTrue(sb["available"])
        self.assertEqual(sb["samples_with_breakdown"], 2)
        analyst = sb["stages"][0]
        self.assertEqual(analyst["output_tokens"], [100, 200])
        self.assertEqual(analyst["output_tokens_mean"], 150.0)

    def test_stage_breakdown_unavailable_surfaces_reason(self):
        bd = {"available": False, "reason": "dry-run — no model invoked"}
        recs = [self._proc_rec(10.0, bd), self._proc_rec(10.0, bd)]
        agg = aggregate.aggregate_proc("P", recs)
        sb = agg["stage_breakdown"]
        self.assertFalse(sb["available"])
        self.assertEqual(sb["samples_with_breakdown"], 0)
        self.assertIn("dry-run", sb["reason"])


if __name__ == "__main__":
    unittest.main()
