#!/usr/bin/env bash
# Seed Mongo from the relational seed — the ADR-0003 loop, made runnable. Task 3
# (Mongo-seed path). Three steps, in order, exactly mirroring capture-golden.sh's
# first two so BOTH stores provably descend from ONE seed:
#
#   1. (Re)apply corpus/seed/relational.sql to WwiSeed — the SAME branch-covering
#      seed (ADR-0007) capture-golden.sh reads golden from. Idempotent: the SQL
#      drops+recreates the DB.
#   2. export-relational.py --all-tables → corpus/seed/relational.json. A dumb dump
#      of every base table (geography→WKT, period columns excluded); no value is
#      invented, so it is as deterministic as the seed.
#   3. to_mongo.py --apply → load Mongo. A pure, total transform (one table → one
#      flat collection, decimal→Decimal128, no embedding). The service reads THIS.
#
# Why this matters: the differential compares the generated service's Mongo-backed
# output against golden captured from the ORIGINAL T-SQL over SQL Server. That
# comparison only means something because both sides trace to relational.sql and
# neither was fitted to the other (ADR-0001/0003). This script is that guarantee in
# executable form — run it, and Mongo holds exactly the seed, nothing hand-shaped.
#
# Usage:
#   bash corpus/seed/seed-mongo.sh
#
# Honours MONGO_URI (default mongodb://localhost:37017/wwi) and MSSQL_SA_PASSWORD
# (from .env). Reseeds SQL every run so Mongo can never drift from an ambient DB.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a
: "${MSSQL_SA_PASSWORD:?set MSSQL_SA_PASSWORD in .env}"

SVC="mssql"
DB="WwiSeed"
MONGO_URI="${MONGO_URI:-mongodb://localhost:37017/wwi}"
REL_JSON="corpus/seed/relational.json"
PY="${PYTHON:-py}"

log() { printf '\033[1;34m[seed-mongo]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[seed-mongo] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[seed-mongo] OK:\033[0m %s\n' "$*"; }

# sqlcmd in the container. MSYS_NO_PATHCONV=1 stops Git-Bash rewriting the exec
# path; -b makes it exit non-zero on a SQL error. Same shape as capture-golden.sh.
run_sql() {
  MSYS_NO_PATHCONV=1 docker compose exec -T "$SVC" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b "$@"
}

# 1. Reseed SQL Server from the committed seed (idempotent).
log "applying relational seed → $DB"
run_sql -i /corpus/seed/relational.sql >/dev/null \
  || die "relational.sql failed — the seed does not apply cleanly"

# 2. Export the whole seed to relational.json (the bridge to to_mongo.py). The
#    Python driver runs on the HOST (some Docker Hub images are AV-blocked here);
#    it needs only stdlib + the docker CLI.
log "exporting every base table → $REL_JSON"
"$PY" corpus/seed/export-relational.py --db "$DB" --all-tables --out "$REL_JSON" \
  || die "export-relational.py failed"

# 3. Load Mongo. --apply needs pymongo (present on the host); the transform is a
#    pure function of relational.json, so re-running is deterministic.
log "loading Mongo ($MONGO_URI) from $REL_JSON"
"$PY" corpus/seed/to_mongo.py "$REL_JSON" --apply --uri "$MONGO_URI" \
  || die "to_mongo.py --apply failed (pymongo installed? mongo up on :37017?)"

ok "Mongo seeded from relational.sql — both stores descend from one seed"
