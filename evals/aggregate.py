#!/usr/bin/env python3
"""Aggregate the per-sample live runs into the k=3 distribution run-001.json.

PREREGISTRATION.md fixes **k=3 runs per configuration, to report a distribution
rather than a point**. The harness (harness.py) produces ONE independent sample per
invocation — a full, from-scratch conversion of the run set driven by the real
agent. This script stitches the samples together into the pre-registered
distribution: per proc, `cleared/k`, whether it is `flaky` (differs across the k
runs), and the spread of cost/tokens/retries. It computes nothing the samples don't
already contain — it is pure aggregation, so anyone can recompute run-001.json
from the committed sample files and get the same bytes.

Why sample-then-aggregate, and not a --k loop inside the harness:
  * Each sample is a separately-authorised, separately-priced live run. Splitting
    them keeps every sample individually inspectable and lets a costly run be
    resumed across sessions without re-spending what already succeeded.
  * The samples are committed alongside the aggregate (run-001.sample-0N.json), so
    the distribution is auditable to its inputs, not a summary that erased them.

Independence is AUDITED, not assumed. A sample proc that recorded 0 agent turns did
not actually regenerate — it would be a stale artifact wearing a fresh label, the
same class of dishonesty the pre-registration forbids. Such a proc is flagged
`independent: false` and the aggregate refuses to call the run clean; it is a
finding to investigate, not a pass.

Usage:
  python3 evals/aggregate.py                 # aggregate all run-001.sample-*.json
  python3 evals/aggregate.py --run-id run-002
  python3 evals/aggregate.py --expect-k 3    # fail if fewer than 3 samples exist
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS_DIR = ROOT / "evals" / "results"


def load_samples(run_id):
    """Load every run-<id>.sample-NN.json, sorted by sample number. Each must be a
    live sample (mode == 'live'); a dry-run file can never feed a measured result."""
    pattern = str(RESULTS_DIR / f"{run_id}.sample-*.json")
    files = sorted(glob.glob(pattern))
    samples = []
    for f in files:
        data = json.loads(Path(f).read_text(encoding="utf-8"))
        if data.get("mode") != "live":
            sys.stderr.write(
                f"[aggregate] REFUSING {os.path.basename(f)}: mode={data.get('mode')!r}, "
                f"not 'live'. A distribution is built only from measured samples.\n")
            return None, []
        samples.append((os.path.basename(f), data))
    return files, samples


def by_proc(samples):
    """Regroup [(fname, sample_payload)] into {proc: [(fname, proc_record), ...]}
    preserving sample order, so per-proc lists line up across procs."""
    procs = {}
    order = []
    for fname, payload in samples:
        for rec in payload.get("results", []):
            p = rec["proc"]
            if p not in procs:
                procs[p] = []
                order.append(p)
            procs[p].append((fname, rec))
    return order, procs


def aggregate_proc(proc, records):
    """Collapse a proc's k sample records into one distribution record."""
    outcomes = [r["outcome"] for _, r in records]
    cleared_flags = [bool(r.get("cleared_within_cap")) for _, r in records]
    cleared = sum(cleared_flags)
    k = len(records)

    # Independence audit: a sample that ran the agent for 0 turns did not regenerate.
    turns = [int(r.get("num_turns") or 0) for _, r in records]
    independent = all(t > 0 for t in turns)

    # `flaky` per the pre-registration: the metric differs across the k runs. A proc
    # that clears every run or fails every run is NOT flaky; a mix is.
    flaky = 0 < cleared < k

    # The produced-output hash of a CLEARED sample equals golden by definition, so
    # every cleared sample shares one hash; record it and confirm they agree.
    produced_hashes = {r["identity"]["produced_output_sha256"]
                       for _, r in records if r.get("cleared_within_cap")}
    golden_hashes = {r["identity"]["golden_output_sha256"]
                     for _, r in records if r.get("cleared_within_cap")}
    identity_consistent = len(produced_hashes) <= 1 and len(golden_hashes) <= 1

    costs = [float(r.get("cost_usd") or 0) for _, r in records]
    out_tokens = [int((r.get("tokens") or {}).get("output") or 0) for _, r in records]
    retries = [r.get("retries") for _, r in records]

    return {
        "proc": proc,
        "k": k,
        "cleared": cleared,
        "cleared_within_cap": f"{cleared}/{k}",
        "flaky": flaky,
        "independent": independent,
        "outcomes": outcomes,
        "retries": retries,
        "identity": {
            "produced_output_sha256": next(iter(produced_hashes)) if produced_hashes else None,
            "golden_output_sha256": next(iter(golden_hashes)) if golden_hashes else None,
            "consistent_across_cleared": identity_consistent,
        },
        "cost_usd": {
            "per_sample": [round(c, 6) for c in costs],
            "mean": round(statistics.mean(costs), 6) if costs else 0.0,
            "total": round(sum(costs), 6),
        },
        "output_tokens": out_tokens,
        "num_turns": turns,
        "source_sha256_per_sample": [r.get("source_sha256") for _, r in records],
    }


def main():
    ap = argparse.ArgumentParser(description="aggregate live samples into a k-run distribution")
    ap.add_argument("--run-id", default="run-001", help="stem of the sample files and the output")
    ap.add_argument("--expect-k", type=int, default=None,
                    help="require exactly this many samples; exit non-zero otherwise")
    args = ap.parse_args()

    files, samples = load_samples(args.run_id)
    if not samples:
        sys.stderr.write(f"[aggregate] no live samples matching {args.run_id}.sample-*.json\n")
        return 2

    k = len(samples)
    if args.expect_k is not None and k != args.expect_k:
        sys.stderr.write(
            f"[aggregate] found {k} sample(s), expected {args.expect_k}. "
            f"Run the remaining live samples before publishing run-001.json.\n")
        return 1

    # Fixed fields must agree across samples — a distribution over mixed models or
    # sampling settings is not a distribution, it is a confound.
    models = {s["model"] for _, s in samples}
    temps = {s["temperature"] for _, s in samples}
    snapshots = {r.get("model_snapshot")
                 for _, s in samples for r in s.get("results", []) if r.get("model_snapshot")}
    if len(models) > 1 or len(temps) > 1:
        sys.stderr.write(f"[aggregate] samples disagree on model/temperature: "
                         f"models={models} temps={temps}. Refusing to aggregate.\n")
        return 1

    order, grouped = by_proc(samples)
    per_proc = [aggregate_proc(p, grouped[p]) for p in order]

    proc_runs = sum(pp["k"] for pp in per_proc)
    cleared_runs = sum(pp["cleared"] for pp in per_proc)
    flaky_procs = [pp["proc"] for pp in per_proc if pp["flaky"]]
    non_independent = [pp["proc"] for pp in per_proc if not pp["independent"]]
    all_cleared = cleared_runs == proc_runs and proc_runs > 0
    total_cost = round(sum(pp["cost_usd"]["total"] for pp in per_proc), 6)

    payload = {
        "run_id": args.run_id,
        "mode": "live-aggregate",
        "preregistration": "evals/PREREGISTRATION.md",
        "k": k,
        "model": next(iter(models)),
        "temperature": next(iter(temps)),
        "retry_cap": samples[0][1].get("retry_cap"),
        "model_snapshot": sorted(snapshots),
        "samples": [os.path.basename(f) for f in files],
        "n_procs": len(per_proc),
        "proc_runs": proc_runs,
        "cleared_proc_runs": f"{cleared_runs}/{proc_runs}",
        "flaky_procs": flaky_procs,
        "non_independent_procs": non_independent,
        "clean_sweep": all_cleared and not non_independent,
        "cost_usd_total": total_cost,
        "per_proc": per_proc,
        "note": (
            "Aggregated from the committed per-sample live runs; recompute with "
            "python3 evals/aggregate.py. k<3 is a partial distribution — the "
            "pre-registration fixes k=3. A clean sweep (every proc clears every "
            "run) is a FINDING to investigate under H3, not a headline; see "
            "evals/results/summary.md."
        ),
    }

    out = RESULTS_DIR / f"{args.run_id}.json"
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    sys.stderr.write(
        f"[aggregate] wrote {out}  (k={k}, {cleared_runs}/{proc_runs} proc-runs cleared, "
        f"flaky={flaky_procs or 'none'}, non_independent={non_independent or 'none'})\n")
    if args.expect_k is None and k < 3:
        sys.stderr.write(
            f"[aggregate] NOTE: k={k} < 3. This is a partial distribution; run "
            f"{3 - k} more live sample(s) to satisfy the pre-registration.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
