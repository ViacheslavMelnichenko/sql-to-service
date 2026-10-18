#!/usr/bin/env python3
"""Deterministic AST feature extraction for T-SQL stored procedures.

This is an OBSERVABILITY / GROUNDING tool, not an oracle and not a transpiler. It
parses a procedure's SQL into an AST (sqlglot, dialect=tsql) and emits a structured
*feature card* of FACTS — which joins are INNER vs LEFT, whether TOP is applied after
ORDER BY, FOR JSON shape, which output columns resolve to decimal/money via the schema,
LIKE/CONCAT null-swallow, temporal/history reads, parameters.

What it deliberately does NOT do (ADR-0008):
  * It never emits C# and never decides HOW to convert — it reports WHAT is present.
  * It has NO authority over correctness. The non-circular differential against the
    golden (ADR-0001) remains the sole judge. Nothing in the conversion loop reads the
    cards this tool writes; `gates/features-check.sh` proves that mechanically.

Interpretation (risk, which skill handles it, the plain-English consequence) lives in
the static KIND_CATALOGUE below — NOT in the per-proc output — so a card stays facts
only and the taxonomy has one home.

Determinism mirrors canonicalise.py: sorted keys, `\n` endings, no wall-clock, no
model. Re-running on the same inputs yields byte-identical output, which is what
`features-check.sh` asserts.

Usage
-----
    extract-features.py <Schema.Proc>     # one card -> corpus/features/<Proc>.features.json
    extract-features.py --all             # all procs under corpus/procs/
    extract-features.py --emit-demo       # (re)write demo/features-data.js from the cards
    extract-features.py --all --emit-demo # regenerate everything
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROCS_DIR = os.path.join(HERE, "procs")
FEATURES_DIR = os.path.join(HERE, "features")
SCHEMA_SQL = os.path.join(HERE, "seed", "relational.sql")
DEMO_DATA = os.path.join(ROOT, "demo", "features-data.js")

SCHEMA_VERSION = 1

try:
    import sqlglot
    from sqlglot import exp
    SQLGLOT_VERSION = sqlglot.__version__
except Exception as e:  # pragma: no cover - import guard
    sys.stderr.write(
        "extract-features.py requires sqlglot. Install the pinned version:\n"
        "    python -m pip install -r corpus/requirements.txt\n"
        f"(import error: {e})\n"
    )
    raise SystemExit(2)


# --- Static interpretation. The card carries facts; this carries meaning. ----------
# kind -> (skill, risk, consequence_en, consequence_uk). `skill` must be a real dir
# under .claude/skills/ (or "-"); features-check.sh asserts that.
KIND_CATALOGUE = {
    "join.inner": {
        "skill": "tsql-semantics", "risk": "high",
        "consequence_en": "A row with no match on the joined table is silently dropped.",
        "consequence_uk": "Рядок без відповідності в приєднаній таблиці мовчки відкидається.",
    },
    "join.left": {
        "skill": "tsql-semantics", "risk": "medium",
        "consequence_en": "The row is kept even with no match; absent columns become null.",
        "consequence_uk": "Рядок зберігається навіть без відповідності; відсутні колонки стають null.",
    },
    "top_order": {
        "skill": "tsql-semantics", "risk": "high",
        "consequence_en": "The limit applies after ordering — a wrong order changes which rows survive the page.",
        "consequence_uk": "Ліміт застосовується після сортування — хибний порядок змінює, які рядки лишаться на сторінці.",
    },
    "for_json": {
        "skill": "document-modelling", "risk": "high",
        "consequence_en": "Output is a nested JSON graph; FOR JSON omits null keys and nests by table alias.",
        "consequence_uk": "Вивід — вкладений JSON-граф; FOR JSON опускає null-ключі й вкладає за аліасом таблиці.",
    },
    "decimal_column": {
        "skill": "decimal-mapping", "risk": "high",
        "consequence_en": "A money/quantity column — a float cast here loses precision the customer sees.",
        "consequence_uk": "Грошова/кількісна колонка — приведення до float тут втрачає точність, яку бачить клієнт.",
    },
    "like_concat": {
        "skill": "tsql-semantics", "risk": "medium",
        "consequence_en": "CONCAT treats NULL as '' (unlike +), so a null field still matches on the others.",
        "consequence_uk": "CONCAT трактує NULL як '' (на відміну від +), тож null-поле усе одно збігається за іншими.",
    },
    "temporal": {
        "skill": "tsql-semantics", "risk": "high",
        "consequence_en": "History lives in *_Archive / SYSTEM_TIME; missing it under-reports changed rows.",
        "consequence_uk": "Історія живе в *_Archive / SYSTEM_TIME; пропуск занижує кількість змінених рядків.",
    },
    "set_op": {
        "skill": "tsql-semantics", "risk": "medium",
        "consequence_en": "UNION ALL concatenates arms without de-duplication — rows from both arms appear.",
        "consequence_uk": "UNION ALL склеює гілки без дедуплікації — з'являються рядки обох гілок.",
    },
    "param": {
        "skill": "-", "risk": "low",
        "consequence_en": "A procedure parameter shapes the query; it must map to a service argument.",
        "consequence_uk": "Параметр процедури формує запит; він має відображатися в аргумент сервісу.",
    },
}

# SQL base types that carry fixed-scale decimal money/quantity values.
DECIMAL_TYPES = {
    exp.DataType.Type.DECIMAL,   # sqlglot normalises NUMERIC -> DECIMAL too
    exp.DataType.Type.MONEY,
    exp.DataType.Type.SMALLMONEY,
}

# Display order for the demo dropdown: the three converted (showcase) procs first,
# then the rest of the Website procs, then the remaining Integration procs. Fixed and
# deterministic — no wall-clock, no directory-order dependence.
DEMO_ORDER = [
    "Website.SearchForCustomers",
    "Integration.GetStockHoldingUpdates",
    "Integration.GetTransactionUpdates",
    "Website.SearchForPeople",
    "Website.SearchForStockItems",
    "Website.SearchForStockItemsByTags",
    "Website.SearchForSuppliers",
    "Integration.GetCityUpdates",
    "Integration.GetCustomerUpdates",
    "Integration.GetMovementUpdates",
    "Integration.GetOrderUpdates",
    "Integration.GetPurchaseUpdates",
    "Integration.GetSaleUpdates",
    "Integration.GetSupplierUpdates",
]

RETURN_STMT = re.compile(r"RETURN\s+\d+\s*;", re.IGNORECASE)


# --- Schema map: {("schema.table", "column") -> DataType.Type} ----------------------

def _strip_brackets(name: str) -> str:
    return name.replace("[", "").replace("]", "").strip()


def build_schema_map(schema_sql: str):
    """Parse every CREATE TABLE block in relational.sql into a decimal-type lookup.

    sqlglot cannot parse the whole file (GO batches, ALTER ... ADD, temporal/geography
    clauses fall to Command nodes and swallow neighbours). So we isolate each
    `CREATE TABLE <name> ( ... )` span by a balanced-paren scan and parse each block on
    its own; a block that still won't parse falls back to a regex column scan. Only
    decimal-bearing columns need to be recorded — a missing key means "unknown", never
    "not decimal".
    """
    schema_map = {}
    for table, body in _iter_create_table_blocks(schema_sql):
        cols = _columns_from_block(table, body)
        schema_map.update(cols)
    return schema_map


def _iter_create_table_blocks(sql: str):
    """Yield (qualified_table_name, column_body_text) for each CREATE TABLE."""
    pat = re.compile(r"CREATE\s+TABLE\s+(\[?\w+\]?\.\[?\w+\]?|\[?\w+\]?)\s*\(", re.IGNORECASE)
    for m in pat.finditer(sql):
        table = _strip_brackets(m.group(1))
        # Balanced-paren scan from the opening '(' that the regex matched.
        start = m.end() - 1
        depth = 0
        end = None
        for i in range(start, len(sql)):
            c = sql[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end is None:
            continue
        yield table, sql[start + 1:end]


def _columns_from_block(table: str, body: str):
    """Try sqlglot on a reconstructed CREATE TABLE; fall back to regex on the body."""
    out = {}
    stmt = f"CREATE TABLE {table} ({body})"
    try:
        tree = sqlglot.parse_one(stmt, dialect="tsql")
        for cdef in tree.find_all(exp.ColumnDef):
            kind = cdef.args.get("kind")
            col = _strip_brackets(cdef.name)
            if isinstance(kind, exp.DataType) and kind.this in DECIMAL_TYPES:
                out[(table, col)] = kind.this
        if out:
            return out
    except Exception:
        pass
    # Regex fallback: find "<col> decimal(.. | numeric(.. | money | smallmoney".
    for cm in re.finditer(
        r"[\[\s,(]\[?(\w+)\]?\s+(decimal|numeric|money|smallmoney)\b",
        body, re.IGNORECASE,
    ):
        out[(table, cm.group(1))] = exp.DataType.Type.DECIMAL
    return out


# --- Per-proc extraction ------------------------------------------------------------

def _table_name_alias(table_exp):
    name = table_exp.sql(dialect="tsql")
    # exp.Table .name/.db give parts; build "schema.table" and the alias separately.
    parts = []
    if table_exp.args.get("db"):
        parts.append(_strip_brackets(table_exp.args["db"].name if hasattr(table_exp.args["db"], "name") else str(table_exp.args["db"])))
    if table_exp.this is not None:
        parts.append(_strip_brackets(table_exp.name))
    qname = ".".join([p for p in parts if p]) or _strip_brackets(name)
    alias = ""
    if table_exp.alias:
        alias = _strip_brackets(table_exp.alias)
    return qname, alias


def _alias_map_for_select(select):
    """alias (and bare name) -> qualified table name, for one SELECT scope."""
    amap = {}
    from_ = select.args.get("from_")
    tables = []
    if from_ is not None:
        tables.extend(from_.find_all(exp.Table))
    for j in select.args.get("joins", []) or []:
        tables.extend(j.find_all(exp.Table))
    for t in tables:
        qname, alias = _table_name_alias(t)
        if alias:
            amap[alias] = qname
        amap[qname.split(".")[-1]] = qname
        amap[qname] = qname
    return amap


def _classify_join(join):
    side = (join.args.get("side") or "")
    side = side.upper() if isinstance(side, str) else ""
    if "LEFT" in side:
        return "join.left"
    if "RIGHT" in side or "FULL" in side:
        return "join.left"  # non-inner outer join — same "row kept" family
    return "join.inner"


def _detect_joins(selects, features):
    seen = set()
    for select in selects:
        from_ = select.args.get("from_")
        left_name = left_alias = ""
        if from_ is not None:
            ft = next(iter(from_.find_all(exp.Table)), None)
            if ft is not None:
                left_name, left_alias = _table_name_alias(ft)
        for j in select.args.get("joins", []) or []:
            kind = _classify_join(j)
            rt = next(iter(j.find_all(exp.Table)), None)
            if rt is None:
                continue
            rname, ralias = _table_name_alias(rt)
            key = (kind, left_name, rname)
            if key in seen:
                continue
            seen.add(key)
            lhs = f"{left_name} {left_alias}".strip()
            rhs = f"{rname} {ralias}".strip()
            features.append({"kind": kind, "detail": f"{lhs} -> {rhs}"})


def _resolve_decimal_output(selects, schema_map, features):
    seen = set()
    for select in selects:
        amap = _alias_map_for_select(select)
        for proj in select.expressions:
            out_name = proj.alias_or_name
            inner = proj.unalias() if hasattr(proj, "unalias") else proj
            # A CAST decides the output type outright — honour it (CAST(x AS int) is NOT
            # decimal even if x is; CAST(x AS decimal) IS).
            cast = inner if isinstance(inner, exp.Cast) else None
            if cast is not None:
                to = cast.to
                if isinstance(to, exp.DataType) and to.this in DECIMAL_TYPES:
                    _add_decimal(features, seen, out_name, to.sql(dialect="tsql"), True)
                continue
            cols = list(inner.find_all(exp.Column))
            if not cols:
                continue
            is_plain = isinstance(inner, exp.Column)
            # COALESCE / multi-arg: resolve on the first column (documented limitation).
            first = cols[0]
            tbl = amap.get(_strip_brackets(first.table)) if first.table else None
            col = _strip_brackets(first.name)
            typ = None
            if tbl:
                typ = schema_map.get((tbl, col))
            if typ in DECIMAL_TYPES:
                if is_plain:
                    _add_decimal(features, seen, out_name, f"{tbl}.{col}", True)
                else:
                    _add_decimal(features, seen, out_name,
                                 f"computed from {tbl}.{col}", False)


def _add_decimal(features, seen, out_name, source, resolved):
    key = (out_name, source, resolved)
    if key in seen:
        return
    seen.add(key)
    detail = f"{out_name} : {source}" if resolved else f"{out_name} : {source} (computed)"
    features.append({"kind": "decimal_column", "detail": detail, "resolved": resolved})


def _detect_for_json(sql, selects, features):
    m = re.search(r"FOR\s+JSON\s+(AUTO|PATH)", sql, re.IGNORECASE)
    if not m and not any(s.args.get("for_") for s in selects):
        return "rowset"
    mode = (m.group(1).upper() if m else "AUTO")
    root = re.search(r"ROOT\s*\(\s*N?'([^']*)'\s*\)", sql, re.IGNORECASE)
    detail = f"FOR JSON {mode}"
    if root:
        detail += f", ROOT('{root.group(1)}')"
    features.append({"kind": "for_json", "detail": detail})
    return "for-json"


def _detect_top_order(selects, features):
    for select in selects:
        if select.args.get("limit") is not None and select.args.get("order") is not None:
            order = select.args["order"]
            cols = [c.alias_or_name for c in order.find_all(exp.Column)]
            features.append({
                "kind": "top_order",
                "detail": f"TOP(...) after ORDER BY {', '.join(cols) or '(expr)'}",
            })
            return


def _detect_like_concat(root, features):
    has_like = next(root.find_all(exp.Like), None) is not None
    has_concat = next(root.find_all(exp.Concat), None) is not None
    if has_like and has_concat:
        features.append({
            "kind": "like_concat",
            "detail": "WHERE CONCAT(...) LIKE pattern (CONCAT treats NULL as '')",
        })


def _detect_temporal(sql, features):
    if re.search(r"FOR\s+SYSTEM_TIME", sql, re.IGNORECASE):
        features.append({"kind": "temporal", "detail": "FOR SYSTEM_TIME history read"})
    archives = sorted(set(re.findall(r"(\w+\.\w+_Archive)", sql, re.IGNORECASE)))
    for a in archives:
        features.append({"kind": "temporal", "detail": f"history table {a}"})
    if re.search(r"DECLARE\s+\w+\s+CURSOR", sql, re.IGNORECASE):
        features.append({"kind": "temporal", "detail": "cursor over history rows"})


def _detect_set_op(sql, features):
    if re.search(r"UNION\s+ALL", sql, re.IGNORECASE):
        features.append({"kind": "set_op", "detail": "UNION ALL (arms combined, no de-dup)"})


def _extract_params(sql, proc_name):
    """Parse the proc header params by regex (robust across sqlglot versions)."""
    m = re.search(r"CREATE\s+PROC(?:EDURE)?\s+\[?\w+\]?\.\[?\w+\]?", sql, re.IGNORECASE)
    if not m:
        return []
    rest = sql[m.end():]
    # Params sit before the first WITH / AS. WITH precedes AS in these headers.
    stop = len(rest)
    for kw in (r"\bWITH\b", r"\bAS\b"):
        km = re.search(kw, rest, re.IGNORECASE)
        if km:
            stop = min(stop, km.start())
    header = rest[:stop]
    params = []
    for pm in re.finditer(r"@(\w+)\s+([A-Za-z0-9_]+(?:\s*\([^)]*\))?)", header):
        ptype = re.sub(r"\s+", "", pm.group(2)).upper()
        params.append({"name": "@" + pm.group(1), "type": ptype})
    return params


def _collect_tables(selects):
    seen = {}
    for select in selects:
        from_ = select.args.get("from_")
        tables = []
        if from_ is not None:
            tables.extend(from_.find_all(exp.Table))
        for j in select.args.get("joins", []) or []:
            tables.extend(j.find_all(exp.Table))
        for t in tables:
            qname, alias = _table_name_alias(t)
            seen.setdefault((qname, alias), {"name": qname, "alias": alias})
    return [seen[k] for k in sorted(seen)]


def extract(proc_name: str, sql: str, schema_map) -> dict:
    card = {
        "schema_version": SCHEMA_VERSION,
        "sqlglot_version": SQLGLOT_VERSION,
        "proc": proc_name,
        "generated_by": "corpus/extract-features.py",
        "parse_status": "ok",
        "params": _extract_params(sql, proc_name),
        "tables": [],
        "output_shape": "rowset",
        "features": [],
        "parse_notes": [],
    }
    features = []
    cleaned = RETURN_STMT.sub("", sql)
    try:
        root = sqlglot.parse_one(cleaned, dialect="tsql")
    except Exception as e:
        card["parse_status"] = "degraded"
        card["parse_notes"].append(f"parse_one failed: {type(e).__name__}")
        root = None

    selects = list(root.find_all(exp.Select)) if root is not None else []
    if root is not None and selects:
        # Detect Command fallbacks (cursors / unsupported inner statements).
        if next(root.find_all(exp.Command), None) is not None:
            card["parse_status"] = "degraded"
            card["parse_notes"].append("some inner statements fell back to Command (regex used)")
        card["tables"] = _collect_tables(selects)
        _detect_joins(selects, features)
        _detect_top_order(selects, features)
        card["output_shape"] = _detect_for_json(sql, selects, features)
        _resolve_decimal_output(selects, schema_map, features)
        _detect_like_concat(root, features)
    else:
        if card["parse_status"] == "ok":
            card["parse_status"] = "degraded"
            card["parse_notes"].append("no SELECT recovered from AST (regex only)")
        _detect_for_json(sql, [], features)

    # Regex-based signals work regardless of parse completeness.
    _detect_temporal(sql, features)
    _detect_set_op(sql, features)

    # Stable ordering for byte-identical re-runs.
    features.sort(key=lambda f: (f["kind"], f["detail"]))
    card["features"] = features
    card["parse_notes"] = sorted(set(card["parse_notes"]))
    return card


# --- IO -----------------------------------------------------------------------------

def _dumps(obj) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, indent=2) + "\n"


def proc_names():
    return sorted(
        f[:-4] for f in os.listdir(PROCS_DIR) if f.endswith(".sql")
    )


def read_proc(proc_name: str) -> str:
    with open(os.path.join(PROCS_DIR, proc_name + ".sql"), encoding="utf-8") as fh:
        return fh.read()


def write_card(proc_name: str, card: dict):
    os.makedirs(FEATURES_DIR, exist_ok=True)
    short = proc_name.split(".", 1)[-1]
    path = os.path.join(FEATURES_DIR, short + ".features.json")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(_dumps(card))
    return path


def build_card(proc_name: str, schema_map) -> dict:
    return extract(proc_name, read_proc(proc_name), schema_map)


def emit_demo(schema_map):
    """Write demo/features-data.js from the cards — the demo's single source of truth."""
    procs = {}
    for name in proc_names():
        card = build_card(name, schema_map)
        procs[name] = {"sql": read_proc(name).strip("\n") + "\n", "card": card}
    order = [p for p in DEMO_ORDER if p in procs] + \
            [p for p in sorted(procs) if p not in DEMO_ORDER]
    payload = {"catalogue": KIND_CATALOGUE, "order": order, "procs": procs}
    body = json.dumps(payload, sort_keys=True, ensure_ascii=False, indent=2)
    with open(DEMO_DATA, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("// GENERATED by corpus/extract-features.py --emit-demo. Do not edit by hand.\n")
        fh.write("// Kept byte-identical to corpus/features/*.json by gates/features-check.sh.\n")
        fh.write("window.FEATURES = " + body + ";\n")
    return DEMO_DATA


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Extract deterministic T-SQL feature cards.")
    ap.add_argument("proc", nargs="?", help="Schema.Proc name (e.g. Website.SearchForCustomers)")
    ap.add_argument("--all", action="store_true", help="process every proc under corpus/procs/")
    ap.add_argument("--emit-demo", action="store_true", help="(re)write demo/features-data.js")
    args = ap.parse_args(argv)

    with open(SCHEMA_SQL, encoding="utf-8") as fh:
        schema_map = build_schema_map(fh.read())

    if args.all:
        for name in proc_names():
            path = write_card(name, build_card(name, schema_map))
            print(f"wrote {os.path.relpath(path, ROOT)}")
    elif args.proc:
        path = write_card(args.proc, build_card(args.proc, schema_map))
        print(f"wrote {os.path.relpath(path, ROOT)}")
    elif not args.emit_demo:
        ap.error("give a proc name, --all, or --emit-demo")

    if args.emit_demo:
        path = emit_demo(schema_map)
        print(f"wrote {os.path.relpath(path, ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
