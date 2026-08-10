#!/usr/bin/env python3
"""Export the seeded SQL tables to the one relational.json that to_mongo.py consumes.

This closes the ADR-0003 loop. `to_mongo.py` is a pure function of the *relational
seed* — but it takes JSON, not SQL. This script is the bridge: it reads the tables
from the same `WwiSeed` database that `capture-golden.sh` seeds and captures golden
from, and writes

    { "<schema.table>": [ {col: value, ...}, ... ], ... }

so BOTH sides of the differential provably descend from one seed. The golden comes
from the original T-SQL over WwiSeed; the Mongo data comes from to_mongo.py over
THIS export of WwiSeed. Neither side is fitted to the other.

Two projection rules, and only two — this stays a dumb, auditable dump:

  * geography -> Well-Known-Text via .STAsText(). FOR JSON refuses the CLR type
    (error 13604), and the seed carries geography as a stable WKT string anyway
    (ADR-0007 tranche 2); to_mongo.py passes that string through verbatim.
  * system-versioning PERIOD columns (ValidFrom/ValidTo generated-always) are
    EXCLUDED. They are versioning plumbing, not domain data — no converted service
    reads them (the temporal procs read history through the proc, not these
    columns), and a generated-always column can't round-trip through a document
    store as data. Everything else is exported verbatim at its SQL type.

Decimals come out of FOR JSON as strings (digits preserved); to_mongo.py maps them
to Decimal128. Dates come out ISO; to_mongo.py maps them to $date. This script adds
no values of its own, so it is as deterministic as the seed.

Usage (host, via the py launcher — mirrors capture-golden.py):
    py corpus/seed/export-relational.py --db WwiSeed \
        --tables Sales.Customers Application.Cities Application.People \
        --out corpus/seed/relational.json
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys


def sqlcmd(db: str, batch: str) -> str:
    """Run one T-SQL batch in the mssql container, return raw stdout.

    Same invocation shape as capture-golden.py: argv list (no shell, so no MSYS
    path rewriting), -y0 for unlimited width (FOR JSON exceeds the default), -b to
    fail loudly on a SQL error."""
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
        raise SystemExit(f"[export] sqlcmd failed (rc={proc.returncode})")
    return proc.stdout


def _join_json_chunks(raw: str) -> str:
    """SQL Server chunks FOR JSON across rows at ~2033 chars; -y0 prints each chunk
    on its own line with no header. Concatenate the non-empty lines verbatim."""
    return "".join(ln for ln in raw.split("\n") if ln != "")


def _split_schema_table(name: str) -> tuple[str, str]:
    if "." not in name:
        raise SystemExit(f"[export] table must be schema-qualified: {name!r}")
    schema, table = name.split(".", 1)
    return schema, table


def all_tables(db: str) -> list[str]:
    """Enumerate every base user table (schema-qualified), ordered deterministically.

    ADR-0003: the Mongo seed is a pure function of the WHOLE relational seed, not a
    hand-picked subset — so the default is to export everything the seed created.
    Includes system-versioned HISTORY tables (they carry the archive rows a temporal
    service reads); to_mongo.py maps each flat, one table -> one collection. Ordered
    by schema then name so the export list is stable across runs."""
    batch = (
        "SET NOCOUNT ON;"
        "SELECT s.name AS s, t.name AS t "
        "FROM sys.tables t "
        "JOIN sys.schemas s ON t.schema_id = s.schema_id "
        "WHERE t.type = 'U' "
        "ORDER BY s.name, t.name "
        "FOR JSON PATH;"
    )
    payload = _join_json_chunks(sqlcmd(db, batch))
    if payload == "":
        raise SystemExit(f"[export] {db}: no base tables found (is the seed applied?)")
    return [f"{r['s']}.{r['t']}" for r in json.loads(payload)]


def columns(db: str, schema: str, table: str) -> list[tuple[str, str]]:
    """Return [(column_name, data_type), ...] for a table, EXCLUDING generated-always
    period columns (system-versioning plumbing). Ordered by ordinal position so the
    export is stable."""
    batch = (
        "SET NOCOUNT ON;"
        "SELECT c.name AS n, t.name AS ty "
        "FROM sys.columns c "
        "JOIN sys.types t ON c.user_type_id = t.user_type_id "
        f"WHERE c.object_id = OBJECT_ID(N'{schema}.{table}') "
        # generated_always_type: 0 = not generated, 1/2 = ROW START/END (period).
        "AND c.generated_always_type = 0 "
        "ORDER BY c.column_id "
        "FOR JSON PATH;"
    )
    payload = _join_json_chunks(sqlcmd(db, batch))
    if payload == "":
        raise SystemExit(f"[export] {schema}.{table}: no columns (does the table exist?)")
    return [(c["n"], c["ty"]) for c in json.loads(payload)]


def _select_list(cols: list[tuple[str, str]]) -> str:
    """Build the SELECT list: geography -> WKT, everything else verbatim by name."""
    parts = []
    for name, ty in cols:
        q = "[" + name.replace("]", "]]") + "]"
        if ty.lower() == "geography":
            parts.append(f"{q}.STAsText() AS {q}")
        else:
            parts.append(q)
    return ", ".join(parts)


def export_table(db: str, name: str) -> list[dict]:
    schema, table = _split_schema_table(name)
    cols = columns(db, schema, table)
    sel = _select_list(cols)
    # INCLUDE_NULL_VALUES so a NULL column survives as explicit JSON null — dropping
    # it would silently change the document shape the service reads.
    batch = (
        "SET NOCOUNT ON;"
        f"SELECT {sel} FROM [{schema}].[{table}] "
        "FOR JSON PATH, INCLUDE_NULL_VALUES;"
    )
    payload = _join_json_chunks(sqlcmd(db, batch))
    if payload == "":
        return []
    rows = json.loads(payload)
    if not isinstance(rows, list):
        raise SystemExit(f"[export] {name}: payload is not an array")
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Export seeded SQL tables to relational.json.")
    ap.add_argument("--db", default="WwiSeed")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--tables", nargs="+",
                   help="schema-qualified table names, e.g. Sales.Customers")
    g.add_argument("--all-tables", action="store_true",
                   help="export every base user table (ADR-0003: whole seed)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                   "relational.json"))
    args = ap.parse_args(argv)

    tables = all_tables(args.db) if args.all_tables else args.tables
    seed: dict[str, list] = {}
    for name in tables:
        rows = export_table(args.db, name)
        seed[name] = rows
        sys.stderr.write(f"[export] {name}: {len(rows)} row(s)\n")

    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        # sort_keys so the file is byte-stable across runs (determinism, like golden).
        json.dump(seed, fh, ensure_ascii=False, sort_keys=True, indent=2)
        fh.write("\n")
    sys.stderr.write(f"[export] wrote {len(seed)} table(s) → {args.out}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
