#!/usr/bin/env python3
"""Canonicalise a result set into the stable JSON normal form the gate compares.

This is the single definition of "the same output" for the whole artifact. Both
sides of the differential — the golden captured from the original T-SQL, and the
output of the generated service — pass through THIS function before comparison, so
"identical" means identical-after-canonicalisation and nothing sneaks in through
representation differences (row order, decimal scale, whitespace, key order).

It is deliberately pure and dependency-free (stdlib only): it must run identically
in the tools container, in CI, and on a reviewer's machine, and it must never need
a model. Determinism here is the foundation the trust rests on.

Normal form
-----------
1. Rows are SORTED by a stable key: the tuple of all their values, JSON-encoded.
   A single result set is an unordered bag UNLESS the procedure's own ORDER BY
   makes order meaningful — and when it does, we preserve it via an explicit
   `--ordered` flag (relevance ranking is part of the output, not noise). Default
   is sorted, because most extracts are set-valued and row order out of SQL is not
   guaranteed without ORDER BY.
2. Object keys are sorted, so column order never affects equality.
3. Numbers are normalised: decimals are emitted at a FIXED scale as strings
   (never as floats — a float round-trip is exactly the precision bug this whole
   artifact is built to catch). Integers stay integers.
4. Strings are stripped of trailing whitespace that CHAR(n) padding introduces in
   SQL Server; NULL stays JSON null.

Usage
-----
    canonicalise.py < raw.json > canonical.json          # sorted (default)
    canonicalise.py --ordered < raw.json > canonical.json  # keep row order
    canonicalise.py --scale 4 < raw.json > canonical.json  # decimal scale

Input is a JSON array of objects (one result set). Output is the same, canonical.
"""
from __future__ import annotations

import argparse
import json
import sys
from decimal import Decimal, InvalidOperation

DEFAULT_SCALE = 4  # WWI money/quantity columns are decimal(18,4)/(18,2); 4 is safe.


def _normalise_number(value, scale: int):
    """Return a canonical representation of a numeric value.

    Decimals become fixed-scale STRINGS so the exact digits are compared, never a
    float's approximation. Bare ints stay ints. Floats are treated as decimals —
    if a float reached here it is already lossy, but we at least pin its scale so
    the comparison is stable rather than platform-dependent.
    """
    if isinstance(value, bool):  # bool is an int subclass — keep it a bool
        return value
    if isinstance(value, int):
        return value
    try:
        d = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return value
    # Quantize to fixed scale, emit as a string to preserve exact digits.
    quant = Decimal(1).scaleb(-scale)  # e.g. scale=4 -> Decimal('0.0001')
    return format(d.quantize(quant), "f")


def _looks_numeric(value) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, (int, float)):
        return True
    if isinstance(value, str):
        try:
            Decimal(value)
            return True
        except InvalidOperation:
            return False
    return False


def canonicalise_value(value, scale: int):
    if value is None:
        return None
    if isinstance(value, str):
        # CHAR(n) padding: SQL Server right-pads fixed-width strings. Trailing
        # whitespace is representation, not content — strip it. Leading is kept.
        return value.rstrip()
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return _normalise_number(value, scale)
    if isinstance(value, list):
        return [canonicalise_value(v, scale) for v in value]
    if isinstance(value, dict):
        return canonicalise_row(value, scale)
    return value


def canonicalise_row(row: dict, scale: int) -> dict:
    """One row: keys sorted, values canonicalised. Numeric-looking strings that
    came from a JSON number stay strings at fixed scale."""
    out = {}
    for key in sorted(row.keys()):
        v = row[key]
        if isinstance(v, str) and _looks_numeric(v) and ("." in v or "e" in v.lower()):
            # A decimal that arrived as a string (e.g. from a JSON serialiser that
            # already stringified it) — pin its scale so both sides match.
            out[key] = _normalise_number(v, scale)
        else:
            out[key] = canonicalise_value(v, scale)
    return out


def canonicalise(rows, scale: int, ordered: bool):
    if not isinstance(rows, list):
        raise ValueError("input must be a JSON array of row objects")
    canon = [canonicalise_row(r, scale) if isinstance(r, dict)
             else canonicalise_value(r, scale) for r in rows]
    if not ordered:
        # Stable sort by the JSON encoding of each row — a total order independent
        # of key/column order because keys are already sorted above.
        canon.sort(key=lambda r: json.dumps(r, sort_keys=True, ensure_ascii=False))
    return canon


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Canonicalise a result set to the gate's normal form.")
    ap.add_argument("--ordered", action="store_true",
                    help="preserve row order (use when the procedure's ORDER BY is part of the output)")
    ap.add_argument("--scale", type=int, default=DEFAULT_SCALE,
                    help=f"decimal scale for numeric normalisation (default {DEFAULT_SCALE})")
    ap.add_argument("infile", nargs="?", help="input JSON file (default: stdin)")
    args = ap.parse_args(argv)

    raw = open(args.infile, encoding="utf-8").read() if args.infile else sys.stdin.read()
    rows = json.loads(raw)
    canon = canonicalise(rows, scale=args.scale, ordered=args.ordered)
    # Compact, deterministic bytes: sorted keys, no incidental whitespace, trailing
    # newline. Byte-identity of this output is what `cleared_within_cap` checks.
    sys.stdout.write(json.dumps(canon, sort_keys=True, ensure_ascii=False,
                                separators=(",", ":")))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
