#!/usr/bin/env python3
"""Eval harness — Phase 4, task 4.x (B.3). The thin, real driver that turns "the
pipeline converts a proc" from an assertion into a measured result.

What it does, for each proc in the run set:
  1. Drives the REAL agent, headless, through the four-stage pipeline
     (analyst -> implementer -> test-author -> reviewer), inside this repo so the
     same hooks that gate an interactive run gate it here too (guard-path,
     post-write-build, stop-differential).
  2. Enforces the RETRY CAP of 2 across attempts (pipeline/retry.md): the hooks
     give in-loop correction; THIS is the hard cap that guarantees termination.
     After the cap it records the proc as a failure with its last gate output —
     a stuck conversion is never silently upgraded to a pass.
  3. Computes the pre-registered primary metric `cleared_within_cap`
     (evals/PREREGISTRATION.md §"Metric definitions"): a proc is cleared iff it
     passed build + unit + differential within the cap AND the canonical output
     the freshly-built service produces is SHA-256 identical to the canonical
     golden. Mechanically checkable; not a judgment.
  4. Records per-proc: outcome, attempts/retries, model+snapshot, tokens, cost,
     wall time, and both SHA-256 hashes — and writes it to evals/results/<run>.json.

Two modes:
  * --dry-run  : NO model, NO API spend. Treats the ALREADY-COMMITTED services as
                 "what the run produced" and exercises every deterministic part of
                 the harness end to end (gates, SHA identity, cost accounting shape,
                 JSON emission). This is what CI and a local run use to prove the
                 scaffold is correct without paying for a model. Cost is 0 and the
                 outcome reflects the committed artifact, honestly labelled.
  * live (default) : spawns `claude -p` per attempt. Requires an environment that
                 permits a headless agent loop with tool access — see run.sh. This
                 spends real API budget and is gated behind an explicit opt-in.

Determinism note: this file pins the model and sampling and records the exact dated
snapshot from the first live invocation into the result (never chosen after the
fact — PREREGISTRATION.md §"Fixed before the run"). In --dry-run the model fields
are recorded as null with mode "dry-run", so a dry result can never be mistaken for
a measured one.

Usage:
  python3 evals/harness.py --dry-run                 # scaffold check, no model
  python3 evals/harness.py --run-id run-001          # live; needs opt-in (run.sh)
  python3 evals/harness.py --dry-run --procs A B C   # override the run set
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS_DIR = ROOT / "evals" / "results"
MANIFEST = ROOT / "generated" / "runners.json"
CASES_DIR = ROOT / "corpus" / "cases"
GOLDEN_DIR = ROOT / "corpus" / "golden"
CANONICALISE = ROOT / "corpus" / "canonicalise.py"


def _resolve_bash():
    """The gate scripts are bash. On Windows the `bash` first on PATH is often
    WSL (C:\\Windows\\System32\\bash.exe), NOT Git Bash — and a broken/absent WSL
    distro makes `bash gates/build.sh` fail instantly with 'execvpe(/bin/bash)
    failed', which the harness would record as failed:build though the service is
    fine. Prefer Git Bash explicitly; let EVAL_BASH override; fall back to plain
    'bash' on non-Windows where PATH bash is the right one.
    """
    override = os.environ.get("EVAL_BASH")
    if override:
        return override
    if os.name == "nt":
        for cand in (
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files\Git\usr\bin\bash.exe",
            r"C:\Program Files (x86)\Git\bin\bash.exe",
        ):
            if Path(cand).exists():
                return cand
    return "bash"


BASH = _resolve_bash()

# --- pre-registered constants (PREREGISTRATION.md — do not tune to fit a result) ---
RETRY_CAP = 2                       # two retries after the first attempt (3 total)
# The model string the gateway CLI expects — the SAME value the interactive Claude
# Code here is configured with (~/.claude/settings.json "model"). It pins the Opus
# family (PREREGISTRATION.md); the exact dated snapshot is captured from the first
# live invocation into model_snapshot, not chosen after the fact. Overridable via
# EVAL_MODEL for a run against a different snapshot without editing this file.
MODEL = os.environ.get("EVAL_MODEL", "claude-opus-4-8-gateway")
TEMPERATURE = 0.0                   # deterministic decoding, recorded for the run

# The run set. Deliberately mixed so run-001 shows a distribution, not a clean
# sweep (H3: "not everything clears, and that's expected"). The first two are the
# converted showcase + decimal proc; the third is picked to be genuinely hard —
# a temporal, multi-arm proc — so at least one honest failure or flaky is expected.
DEFAULT_PROCS = [
    "Website.SearchForCustomers",
    "Integration.GetStockHoldingUpdates",
    "Integration.GetTransactionUpdates",
]

# Per-proc source files that make up a conversion artifact, for the source hash.
# (The output hash is the real metric; the source hash records WHICH artifact was
# measured, so anyone can confirm the committed files are the ones the eval ran.)


def _debug_dump(proc, attempt, kind, text):
    """Opt-in (EVAL_DEBUG=1): write each attempt's raw claude output and gate output
    to evals/results/debug/ so a failing live run can be diagnosed without re-running.
    A no-op unless EVAL_DEBUG is set, so it never touches a normal measured run."""
    if not os.environ.get("EVAL_DEBUG"):
        return
    dbg = RESULTS_DIR / "debug"
    dbg.mkdir(parents=True, exist_ok=True)
    safe = proc.replace("/", "_").replace("\\", "_")
    (dbg / f"{safe}.attempt{attempt}.{kind}.txt").write_text(text, encoding="utf-8")


def sh(cmd, env=None, timeout=None, stdin_text=None):
    """Run a shell command from ROOT; return (rc, stdout+stderr)."""
    proc = subprocess.run(
        cmd, cwd=str(ROOT), shell=isinstance(cmd, str),
        capture_output=True, text=True, env=env, timeout=timeout,
        input=stdin_text,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def load_manifest():
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def load_cases(proc):
    return json.loads((CASES_DIR / f"{proc}.json").read_text(encoding="utf-8"))


def canonicalise(args, stdin_text=None):
    """Call the ONE canonicaliser the gate uses. Returns its stdout (canonical JSON)."""
    proc = subprocess.run(
        [sys.executable, str(CANONICALISE), *args],
        cwd=str(ROOT), input=stdin_text, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"canonicalise failed: {proc.stderr}")
    # The `py` launcher / Windows can introduce CRLF; strip CR so the hash is stable
    # across OSes (same reason the gate scripts pipe through `tr -d '\r'`).
    return proc.stdout.replace("\r\n", "\n")


def build_service(proc, manifest):
    """dotnet build (Release) the proc's csproj; return the built .dll path."""
    csproj = manifest[proc]["csproj"]
    assembly = manifest[proc]["assembly"]
    rc, out = sh(["dotnet", "build", "-c", "Release", "--nologo", csproj])
    if rc != 0:
        raise RuntimeError(f"build failed for {proc}:\n{out}")
    dlls = list((ROOT / "generated" / "bin" / "Release").rglob(f"{assembly}.dll"))
    if not dlls:
        raise RuntimeError(f"built binary not found: {assembly}.dll")
    return str(dlls[0])


def canonical_output_and_golden(proc, manifest):
    """Build+run the CURRENT service over every case, canonicalise, and pair each
    with its canonical golden. Returns (produced_concat, golden_concat) — the two
    strings the SHA-256 identity check hashes. This mirrors gates/differential.sh's
    per-case invocation exactly (same binary, same params, same canonicaliser), so
    the hash is over the same normal form the gate compares."""
    spec = load_cases(proc)
    ordered = ["--ordered"] if spec.get("ordered") else []
    dll = build_service(proc, manifest)
    mongo_uri = os.environ.get("MONGO_URI", "mongodb://localhost:37017/wwi")

    produced_parts, golden_parts = [], []
    for case in spec["cases"]:
        name = case["name"]
        params_json = json.dumps(case.get("params", []))
        rc, raw = sh(["dotnet", dll, params_json, mongo_uri])
        if rc != 0:
            raise RuntimeError(f"runner failed for {proc}/{name}:\n{raw}")
        produced_parts.append(f"{name}\n" + canonicalise(ordered, stdin_text=raw))
        golden_file = GOLDEN_DIR / f"{proc}__{name}.json"
        golden_parts.append(f"{name}\n" + canonicalise(ordered + [str(golden_file)]))
    return "\n".join(produced_parts), "\n".join(golden_parts)


def sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def source_sha256(proc, manifest):
    """Hash the conversion artifact's source (service file), so the result records
    WHICH files were measured — anyone hashes the committed files and confirms
    they are the ones the eval ran, closing the 'was this hand-fixed after?' gap."""
    service = ROOT / manifest[proc]["service"]
    h = hashlib.sha256()
    h.update(service.read_bytes())
    return h.hexdigest()


def run_gates(proc):
    """Run build + unit + per-proc differential — the same verdict verify.sh gives,
    but decomposed so the failure taxonomy can name WHICH gate failed. Returns
    (outcome, detail). outcome is 'cleared' or 'failed:<gate>'."""
    rc, out = sh([BASH, "gates/build.sh", proc])
    if rc != 0:
        return "failed:build", out
    rc, out = sh([BASH, "gates/unit.sh"])
    if rc != 0:
        return "failed:unit", out
    rc, out = sh([BASH, "gates/differential.sh", proc])
    if rc != 0:
        return "failed:differential", out
    return "cleared", out


# --------------------------------------------------------------------------------
# Live conversion — drives the real agent. Bounded by the retry cap.
# --------------------------------------------------------------------------------

def convert_live(proc):
    """Drive `claude -p` through the pipeline for ONE proc, up to RETRY_CAP retries.

    Returns a dict with attempts, retries, model snapshot, token/cost totals, and
    the last gate output. The Stop hook (stop-differential.sh, made proc-aware via
    CONVERT_PROC) blocks an early finish inside each session; THIS loop is the hard
    across-attempts cap that guarantees termination (pipeline/retry.md)."""
    prompt = build_conversion_prompt(proc)
    # CONVERT_PROC makes the Stop hook proc-aware. CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0
    # is load-bearing: with it left at 1 (the interactive default here), the child
    # `claude` FORCES permission-mode back to default and ignores --permission-mode
    # acceptEdits, so the headless agent can never write a file and every attempt
    # ends with 0 turns. Turning the scrub OFF for this child restores acceptEdits;
    # the Foundry key is already present in this shell (we run outside a Claude Code
    # session, per run-live.ps1), so auth is unaffected.
    env = dict(os.environ, CONVERT_PROC=proc, CLAUDE_CODE_SUBPROCESS_ENV_SCRUB="0")

    totals = {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "num_turns": 0}
    snapshot = None
    session_id = None
    last_gate = ""
    attempt = 0

    while attempt <= RETRY_CAP:
        attempt += 1
        cmd = [
            "claude", "-p",
            "--output-format", "json",
            "--model", MODEL,
            "--permission-mode", "acceptEdits",
            "--allowedTools", "Read,Grep,Glob,Write,Edit,Bash,Task,Skill",
        ]
        if session_id:
            # Resume with the gate's feedback as the correction (the across-attempts
            # half of the retry protocol) rather than starting cold.
            cmd += ["--resume", session_id]
            turn_prompt = retry_prompt(proc, last_gate)
        else:
            turn_prompt = prompt

        # Feed the prompt over STDIN, not as a positional arg. Through the Windows
        # `claude.cmd` shim a long trailing argument is dropped and the CLI aborts
        # with "Input must be provided either through stdin or as a prompt argument"
        # (0 turns, ~3s) — exactly the empty attempts run-001 recorded. --print reads
        # stdin when no prompt arg is given, so this is the portable path.
        rc, raw = sh(cmd, env=env, timeout=1800, stdin_text=turn_prompt)
        _debug_dump(proc, attempt, "claude", f"rc={rc}\n\n{raw}")
        meta = parse_claude_json(raw)
        if meta:
            session_id = meta.get("session_id", session_id)
            snapshot = snapshot or meta.get("model_snapshot")
            u = meta.get("usage", {})
            totals["input_tokens"] += int(u.get("input_tokens", 0) or 0)
            totals["output_tokens"] += int(u.get("output_tokens", 0) or 0)
            totals["cost_usd"] += float(meta.get("total_cost_usd", 0) or 0)
            totals["num_turns"] += int(meta.get("num_turns", 0) or 0)

        outcome, last_gate = run_gates(proc)
        _debug_dump(proc, attempt, "gate", f"outcome={outcome}\n\n{last_gate}")
        if outcome == "cleared":
            return {"attempts": attempt, "retries": attempt - 1, "snapshot": snapshot,
                    "totals": totals, "gate_outcome": outcome, "last_gate": last_gate}

    # Cap exhausted: record the failure honestly with its last gate outcome.
    return {"attempts": attempt, "retries": attempt - 1, "snapshot": snapshot,
            "totals": totals, "gate_outcome": outcome, "last_gate": last_gate,
            "note": "retry cap exhausted"}


def parse_claude_json(raw):
    """`claude -p --output-format json` emits one JSON object, but the CLI can
    append a trailing line to the same stream (e.g. the `Permission mode forced
    to default ...` scrub warning). Parsing raw[start:] whole then chokes on that
    tail (JSONDecodeError -> None -> tokens/cost recorded as 0 though the agent
    ran). Decode just the FIRST object with raw_decode and ignore whatever follows.
    Still forgiving of leading noise (NuGet advisories etc.)."""
    raw = raw.replace("\r\n", "\n").strip()
    start = raw.find("{")
    if start < 0:
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(raw[start:])
    except json.JSONDecodeError:
        return None
    # The dated snapshot the run actually hit. `model` is usually null on this
    # gateway; the real pin is modelUsage[<key>].canonicalModel (e.g.
    # "claude-opus-4-8"), captured here so PREREGISTRATION's snapshot is recorded
    # from the run, not chosen after. Fall back to the modelUsage key itself.
    model_snapshot = None
    mu = obj.get("modelUsage") or {}
    if isinstance(mu, dict) and mu:
        first_key = next(iter(mu.keys()))
        entry = mu.get(first_key) or {}
        model_snapshot = (entry.get("canonicalModel") if isinstance(entry, dict) else None) or first_key
    return {
        "session_id": obj.get("session_id"),
        "total_cost_usd": obj.get("total_cost_usd"),
        "usage": obj.get("usage") or {},
        "num_turns": obj.get("num_turns"),
        "model_snapshot": obj.get("model") or model_snapshot,
    }


def build_conversion_prompt(proc):
    return (
        f"Convert the T-SQL stored procedure {proc} to a .NET service over the flat "
        f"Mongo seed, using the staged pipeline. Dispatch the subagents in order: "
        f"first the `analyst` to write generated/{proc}.spec.md, then the "
        f"`implementer` to write the service + csproj + runner under generated/, "
        f"then the `test-author` to write its unit tests, then the `reviewer` to "
        f"run the gate. Add the proc to generated/runners.json. Write ONLY under "
        f"generated/. Do not finish until gates/differential.sh {proc} is green — "
        f"the Stop hook enforces this."
    )


def retry_prompt(proc, last_gate):
    tail = "\n".join(last_gate.splitlines()[-40:])
    return (
        f"The gate for {proc} is still red. Fix the service under generated/ only — "
        f"do not touch corpus/, the seed, or the comparison. Here is the last gate "
        f"output:\n\n{tail}"
    )


# --------------------------------------------------------------------------------
# Result assembly
# --------------------------------------------------------------------------------

def evaluate_proc(proc, manifest, dry_run):
    """Produce one proc's result record. In dry-run, the 'run' is the committed
    artifact and no model is invoked; live, convert_live drives the agent."""
    t0 = time.time()
    record = {"proc": proc, "outcome": None, "retries": None, "attempts": None}

    if dry_run:
        # No model. Measure the committed artifact exactly as the gate would.
        gate_outcome, gate_out = run_gates(proc)
        totals = {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "num_turns": 0}
        snapshot = None
        attempts = retries = 0
    else:
        conv = convert_live(proc)
        gate_outcome, gate_out = conv["gate_outcome"], conv["last_gate"]
        totals = conv["totals"]
        snapshot = conv["snapshot"]
        attempts, retries = conv["attempts"], conv["retries"]
        # The agent ADDS the converted proc to generated/runners.json during the run,
        # so the manifest loaded at startup is stale for a newly-converted proc. Reload
        # from disk here — without it build_service/source_sha256 KeyError on the new
        # key AFTER a clean gate, turning a genuine pass into a spurious "error" (and
        # discarding its tokens/cost). This is exactly what happened to run-001's third
        # proc: it cleared, then the stale manifest masked it.
        manifest = load_manifest()

    # The SHA-256 identity check (the pre-registered primary metric). Only meaningful
    # if the differential passed — a red gate can't be "identical to golden".
    produced_sha = golden_sha = None
    identity_ok = False
    if gate_outcome == "cleared":
        produced, golden = canonical_output_and_golden(proc, manifest)
        produced_sha, golden_sha = sha256(produced), sha256(golden)
        identity_ok = produced_sha == golden_sha

    within_cap = retries is not None and retries <= RETRY_CAP
    cleared_within_cap = gate_outcome == "cleared" and identity_ok and within_cap

    record.update({
        "outcome": "cleared" if cleared_within_cap else gate_outcome,
        "cleared_within_cap": cleared_within_cap,
        "attempts": attempts,
        "retries": retries,
        "identity": {
            "produced_output_sha256": produced_sha,
            "golden_output_sha256": golden_sha,
            "match": identity_ok,
        },
        "source_sha256": source_sha256(proc, manifest) if proc in manifest else None,
        "model_snapshot": snapshot,
        "tokens": {"input": totals["input_tokens"], "output": totals["output_tokens"]},
        "cost_usd": round(totals["cost_usd"], 6),
        "num_turns": totals["num_turns"],
        "wall_seconds": round(time.time() - t0, 1),
    })
    return record


def main():
    ap = argparse.ArgumentParser(description="sql-to-service eval harness (B.3)")
    ap.add_argument("--dry-run", action="store_true",
                    help="no model / no API spend; measure the committed artifact")
    ap.add_argument("--run-id", default=None,
                    help="result file stem (default: run-001 live, dry-run scratch)")
    ap.add_argument("--procs", nargs="*", default=None,
                    help="override the run set (space-separated proc names)")
    args = ap.parse_args()

    if not args.dry_run and not os.environ.get("EVAL_LIVE_OK"):
        sys.stderr.write(
            "[harness] REFUSING to start a LIVE run: EVAL_LIVE_OK is not set.\n"
            "  A live run spends real API budget and drives a headless agent loop.\n"
            "  Run the scaffold check with:  python3 evals/harness.py --dry-run\n"
            "  Authorise a live run via run.sh, which sets EVAL_LIVE_OK after an\n"
            "  explicit confirmation (see evals/run.sh).\n")
        return 3

    manifest = load_manifest()
    # A dry run can only measure artifacts that EXIST — default it to the converted
    # procs in the manifest, so it proves the scaffold against committed reality.
    # A live run defaults to the mixed set (incl. an as-yet-unconverted, genuinely
    # hard proc) so run-001 shows a distribution, not a rigged sweep (H3).
    manifest_procs = [p for p in manifest if p != "//"]
    if args.procs:
        procs = args.procs
    elif args.dry_run:
        procs = manifest_procs
    else:
        procs = DEFAULT_PROCS
    run_id = args.run_id or ("dry-run" if args.dry_run else "run-001")

    mode = "dry-run" if args.dry_run else "live"
    sys.stderr.write(f"[harness] mode={mode} run_id={run_id} procs={procs}\n")

    results = []
    for proc in procs:
        sys.stderr.write(f"[harness] evaluating {proc} ...\n")
        try:
            results.append(evaluate_proc(proc, manifest, args.dry_run))
        except Exception as e:  # noqa: BLE001 — a proc that errors is a result, not a crash
            results.append({"proc": proc, "outcome": "error", "error": str(e),
                            "cleared_within_cap": False})

    cleared = sum(1 for r in results if r.get("cleared_within_cap"))
    payload = {
        "run_id": run_id,
        "mode": mode,
        "preregistration": "evals/PREREGISTRATION.md",
        "model": None if args.dry_run else MODEL,
        "temperature": None if args.dry_run else TEMPERATURE,
        "retry_cap": RETRY_CAP,
        "gate_bash": BASH,
        "n_procs": len(results),
        "cleared_within_cap": cleared,
        "results": results,
        "note": (
            "DRY RUN — measures the already-committed conversion artifacts with NO "
            "model in the loop. Costs are 0 and model fields null by construction. "
            "This proves the harness scaffold end to end; it is NOT the measured "
            "eval result and must never be cited as run-001."
            if args.dry_run else
            "Live run: model-driven conversion, real API cost. Snapshot captured "
            "from the first invocation and recorded above."
        ),
    }

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    out_file = RESULTS_DIR / f"{run_id}.json"
    out_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    sys.stderr.write(f"[harness] wrote {out_file}  ({cleared}/{len(results)} cleared_within_cap)\n")

    # Exit non-zero if the DRY RUN's scaffold is broken (a committed proc no longer
    # clears), so CI catches a regression. A live run always exits 0 — an honest
    # failure is a valid result, not a harness error.
    if args.dry_run and cleared != len(results):
        sys.stderr.write("[harness] dry-run: a committed proc did not clear — scaffold regression\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
