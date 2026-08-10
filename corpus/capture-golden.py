#!/usr/bin/env python3
"""Capture golden output for the tranche-1 procedures — the ADR-0001 oracle.

Golden is captured by running the ORIGINAL, verbatim T-SQL procedures against the
purpose-built relational seed (ADR-0007), with NO model in the room. Because the
seed is the whole input (corpus/seed/relational.sql), golden is a pure function of
the seed by construction (ADR-0003). This script is the mechanism.

It reads one case file per procedure (corpus/cases/<Proc>.json), runs each case's
parameter set against SQL Server, and writes one canonical golden file per case to
corpus/golden/<Proc>__<case>.json. Both output shapes are handled:

  * "for-json"  — the 5 Website.SearchFor* procs end in FOR JSON AUTO, ROOT(name).
                  SQL Server chunks the JSON across rows at ~2033 chars; we
                  concatenate the chunks, parse, and UNWRAP the single ROOT key so
                  golden is a bare array of rows (the root wrapper is constant per
                  proc and carries no per-case information; the differential is
                  value-based, ADR-0001/§3.3).
  * "tabular"   — the 6 Integration.Get*Updates return rows. We wrap the EXEC in a
                  dynamically-typed #temp table (columns discovered via
                  sys.dm_exec_describe_first_result_set) and serialise with
                  FOR JSON PATH, INCLUDE_NULL_VALUES so NULL columns survive as
                  explicit JSON null (a dropped-NULL would hide a branch).

Every result passes through corpus/canonicalise.py before it is written, so golden
is already in the gate's normal form: rows sorted (unless the proc's own ORDER BY
makes order meaningful, per the case file's "ordered" flag), keys sorted, decimals
as fixed-scale strings. The bytes this writes are byte-identical to what the
differential will canonicalise the generated service's output into.

Determinism: the seed uses only fixed literals and this script adds none of its
own, so two runs produce byte-identical golden — which is exactly what
gates/verify-stable.sh (task 1.9) checks.

Usage (normally invoked by capture-golden.sh, which reseeds + loads the procs):
    py corpus/capture-golden.py --db WwiSeed --cases corpus/cases --out corpus/golden
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import canonicalise  # noqa: E402  (sibling module, corpus/canonicalise.py)


def sqlcmd(db: str, batch: str) -> str:
    """Run one T-SQL batch in the mssql container, return raw stdout.

    Invoked as an argv list (no shell), so the container exec path is not subject
    to MSYS path rewriting and the batch text needs no shell quoting. -y0 gives
    unlimited column width (FOR JSON output exceeds the default and would truncate);
    -h -1 cannot be combined with -y0, so headers are stripped in Python instead.
    """
    password = os.environ["MSSQL_SA_PASSWORD"]
    proc = subprocess.run(
        [
            "docker", "compose", "exec", "-T", "mssql",
            "/opt/mssql-tools18/bin/sqlcmd",
            "-S", "localhost", "-U", "sa", "-P", password,
            "-C", "-No", "-b", "-d", db, "-y0",
            "-Q", batch,
        ],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"[capture] sqlcmd failed (rc={proc.returncode})")
    return proc.stdout


def _join_json_chunks(raw: str) -> str:
    """Reconstruct one JSON string from sqlcmd's output.

    SQL Server returns FOR JSON as one unnamed column chunked across rows at ~2033
    chars; with -y0 sqlcmd prints each chunk on its own line with no header and no
    padding. Empty result sets print nothing. So: concatenate the non-empty lines
    verbatim (no per-line stripping — that could eat a space inside a JSON string
    that happened to land on a chunk boundary)."""
    lines = [ln for ln in raw.split("\n") if ln != ""]
    return "".join(lines)


def _exec_literal(proc: str, params: list) -> str:
    """Build the raw `EXEC Schema.Proc @P=<v>, ...` command for a case."""
    if not params:
        return f"EXEC {proc}"
    parts = []
    for p in params:
        name, typ, val = p["name"], p["type"], p["value"]
        if typ == "int":
            lit = str(int(val))
        elif typ in ("nvarchar", "datetime2"):
            # String literal; double single quotes. datetime2 is passed as a string
            # and SQL Server converts it (the T separator is accepted here).
            lit = "N'" + str(val).replace("'", "''") + "'"
        else:
            raise SystemExit(f"[capture] unsupported param type {typ!r} for {proc}")
        parts.append(f"@{name}={lit}")
    return f"EXEC {proc} " + ", ".join(parts)


def capture_for_json(db: str, proc: str, params: list) -> list:
    """Run a FOR JSON proc, return the unwrapped array of row objects."""
    raw = sqlcmd(db, "SET NOCOUNT ON; " + _exec_literal(proc, params) + ";")
    payload = _join_json_chunks(raw)
    if payload == "":
        return []  # empty result: FOR JSON emits no rows
    doc = json.loads(payload)
    # FOR JSON AUTO, ROOT(name) -> {"<Root>": [ ...rows... ]}. Unwrap the single
    # key. A missing/multi-key shape is a contract violation worth failing loudly.
    if not isinstance(doc, dict) or len(doc) != 1:
        raise SystemExit(f"[capture] {proc}: expected a single-root object, got {type(doc).__name__} keys={list(doc) if isinstance(doc, dict) else '-'}")
    (rows,) = doc.values()
    if not isinstance(rows, list):
        raise SystemExit(f"[capture] {proc}: root value is not an array")
    return rows


def capture_tabular(db: str, proc: str, params: list) -> list:
    """Run a row-returning proc via a dynamically-typed #temp, return row objects.

    The column list is discovered from the proc's first result set, so this stays a
    pure function of the proc text — no column names are hand-declared here (that
    would be a place to silently drift from the proc)."""
    exec_lit = _exec_literal(proc, params)
    exec_embedded = exec_lit.replace("'", "''")  # @exec is itself an N'...' literal
    batch = (
        "SET NOCOUNT ON;"
        f"DECLARE @exec nvarchar(max) = N'{exec_embedded}';"
        "DECLARE @cols nvarchar(max) = N'';"
        "SELECT @cols = @cols + CASE WHEN @cols = N'' THEN N'' ELSE N',' END"
        "  + QUOTENAME(name) + N' ' + system_type_name"
        "  FROM sys.dm_exec_describe_first_result_set(@exec, NULL, 0)"
        "  ORDER BY column_ordinal;"
        "DECLARE @batch nvarchar(max) = N'CREATE TABLE #cap (' + @cols + N');'"
        "  + N'INSERT INTO #cap ' + @exec + N';'"
        "  + N'SELECT * FROM #cap FOR JSON PATH, INCLUDE_NULL_VALUES;';"
        "EXEC sys.sp_executesql @batch;"
    )
    payload = _join_json_chunks(sqlcmd(db, batch))
    if payload == "":
        return []  # empty result: FOR JSON PATH over an empty #cap emits no rows
    rows = json.loads(payload)
    if not isinstance(rows, list):
        raise SystemExit(f"[capture] {proc}: tabular payload is not an array")
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Capture golden output for tranche-1 procs.")
    ap.add_argument("--db", default="WwiSeed")
    ap.add_argument("--cases", default=os.path.join(HERE, "cases"))
    ap.add_argument("--out", default=os.path.join(HERE, "golden"))
    ap.add_argument("--scale", type=int, default=canonicalise.DEFAULT_SCALE)
    args = ap.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    case_files = sorted(f for f in os.listdir(args.cases) if f.endswith(".json"))
    if not case_files:
        raise SystemExit(f"[capture] no case files in {args.cases}")

    total = 0
    for cf in case_files:
        spec = json.loads(open(os.path.join(args.cases, cf), encoding="utf-8").read())
        proc = spec["proc"]
        shape = spec["shape"]
        ordered = bool(spec.get("ordered", True))
        for case in spec["cases"]:
            name = case["name"]
            params = case.get("params", [])
            if shape == "for-json":
                rows = capture_for_json(args.db, proc, params)
            elif shape == "tabular":
                rows = capture_tabular(args.db, proc, params)
            else:
                raise SystemExit(f"[capture] {proc}: unknown shape {shape!r}")

            canon = canonicalise.canonicalise(rows, scale=args.scale, ordered=ordered)
            out_path = os.path.join(args.out, f"{proc}__{name}.json")
            with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(json.dumps(canon, sort_keys=True, ensure_ascii=False,
                                    separators=(",", ":")))
                fh.write("\n")
            sys.stderr.write(f"[capture] {proc}__{name}: {len(canon)} row(s)\n")
            total += 1

    sys.stderr.write(f"[capture] wrote {total} golden files to {args.out}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
