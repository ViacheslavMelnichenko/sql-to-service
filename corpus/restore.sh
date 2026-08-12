#!/usr/bin/env bash
# Download the pinned WideWorldImporters-Standard.bak, verify its SHA-256, and
# restore it into the mssql container. This is step one of Phase 1: it stands up
# the SOURCE OF TRUTH — the original T-SQL — with no model anywhere near it.
#
# Supply-chain stance (see corpus/SOURCE.md): a changed upstream file is an EVENT,
# not something to restore silently. If CORPUS_BAK_SHA256 is set and the download
# does not match, we abort. If it is blank (first run), we print the computed SHA
# and tell you to pin it.
#
# Usage:  ./corpus/restore.sh        # from the repo root, stack already `up`
set -euo pipefail

# --- config from .env (compose already loaded it into the container, but this
#     script runs on the host and talks to the container, so read it here too) ---
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a

: "${MSSQL_SA_PASSWORD:?set MSSQL_SA_PASSWORD in .env}"
BAK_URL="${CORPUS_BAK_URL:?set CORPUS_BAK_URL in .env}"
PINNED_SHA="${CORPUS_BAK_SHA256:-}"

BAK_DIR="$ROOT/corpus/_bak"
BAK_FILE="$BAK_DIR/WideWorldImporters-Standard.bak"
# Path as the container sees it (mounted in docker-compose.yml):
BAK_IN_CONTAINER="/var/opt/mssql/backup/WideWorldImporters-Standard.bak"
SVC="mssql"
DB="WideWorldImporters"

log() { printf '\033[1;34m[restore]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[restore] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# sqlcmd inside the container (2022 image ships it at tools18). -C trusts the
# self-signed cert; -b makes a T-SQL error a non-zero exit. MSYS_NO_PATHCONV=1
# stops Git Bash on Windows from rewriting the container-side /opt path into a
# host path (a no-op on Linux/CI).
sql() {
  MSYS_NO_PATHCONV=1 docker compose exec -T "$SVC" /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b "$@"
}

# --- 1. download (skip if already present and pinned-SHA matches) -------------
# Download on the HOST: the host trusts whatever root CA is in play (incl. a
# corporate TLS-inspecting proxy), which a bare container does not. On Linux/CI
# the plain call succeeds; on a Windows host behind a proxy whose schannel can't
# reach the revocation endpoint (CRYPT_E_NO_REVOCATION_CHECK) we retry ONCE with
# --ssl-no-revoke, which relaxes revocation checking ONLY — cert validation still
# happens, and the flag is a harmless no-op on the Linux path. The SHA
# gate below is the real integrity check regardless.
mkdir -p "$BAK_DIR"
if [ ! -f "$BAK_FILE" ]; then
  log "downloading .bak (~120 MB) from $BAK_URL"
  if ! curl -fSL --retry 3 -o "$BAK_FILE" "$BAK_URL"; then
    log "retrying with --ssl-no-revoke (schannel revocation-check workaround)"
    curl -fSL --retry 3 --ssl-no-revoke -o "$BAK_FILE" "$BAK_URL" \
      || die "download failed — check CORPUS_BAK_URL or your network/proxy"
  fi
else
  log "using cached $BAK_FILE"
fi

# --- 2. SHA-256 gate ----------------------------------------------------------
ACTUAL_SHA="$(sha256sum "$BAK_FILE" | awk '{print $1}')"
if [ -z "$PINNED_SHA" ]; then
  log "no pinned SHA yet. Computed:"
  printf '\n    CORPUS_BAK_SHA256=%s\n\n' "$ACTUAL_SHA"
  log "paste that into .env (and corpus/SOURCE.md) to pin it, then re-run."
  log "continuing this run UNPINNED — first-run bootstrap only."
elif [ "$ACTUAL_SHA" != "$PINNED_SHA" ]; then
  die "SHA-256 MISMATCH — supply-chain event.
       expected $PINNED_SHA
       actual   $ACTUAL_SHA
       Refusing to restore. If upstream legitimately changed, update the pin in
       .env + corpus/SOURCE.md WITH a note in CHANGELOG.md."
else
  log "SHA-256 verified against pin ✓"
fi

# --- 3. wait for the engine ---------------------------------------------------
log "waiting for SQL Server to accept connections…"
for i in $(seq 1 30); do
  if sql -Q "SELECT 1" -h -1 >/dev/null 2>&1; then break; fi
  [ "$i" = 30 ] && die "SQL Server did not become ready in time"
  sleep 2
done
log "engine is up"

# --- 4. read logical file names from the backup, then RESTORE with MOVE -------
log "restoring $DB (idempotent — drops and re-restores if present)"
sql -Q "IF DB_ID('$DB') IS NOT NULL BEGIN
           ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
           DROP DATABASE [$DB];
         END"

# WWI-Standard's logical names are stable, but read them rather than hard-code:
sql -Q "RESTORE FILELISTONLY FROM DISK = N'$BAK_IN_CONTAINER'" -s "|" -W \
  > "$BAK_DIR/filelist.txt" || die "RESTORE FILELISTONLY failed"

# The Standard .bak carries exactly three files (Primary / UserData / Log) — NO
# in-memory filegroup. That absence is precisely why we pinned Standard over Full
# (see corpus/SOURCE.md): the Full backup's in-memory file will not restore in the
# Linux container. If FILELISTONLY above ever shows a fourth logical name, this is
# the block to update.
sql -Q "RESTORE DATABASE [$DB]
         FROM DISK = N'$BAK_IN_CONTAINER'
         WITH MOVE N'WWI_Primary'   TO N'/var/opt/mssql/data/WideWorldImporters.mdf',
              MOVE N'WWI_UserData'  TO N'/var/opt/mssql/data/WideWorldImporters_UserData.ndf',
              MOVE N'WWI_Log'       TO N'/var/opt/mssql/data/WideWorldImporters.ldf',
              REPLACE, RECOVERY" \
  || die "RESTORE DATABASE failed — see filelist.txt for the real logical names"

# --- 5. sanity: the DB is online and carries our target schemas ---------------
# USE the DB so sys.schemas resolves inside WideWorldImporters, not master.
COUNT="$(sql -h -1 -W -Q "SET NOCOUNT ON; USE [$DB];
  SELECT COUNT(*) FROM sys.procedures p
  JOIN sys.schemas s ON s.schema_id = p.schema_id
  WHERE s.name IN ('Website','Integration');" | grep -oE '[0-9]+' | tail -1)"
log "restore complete. Website+Integration procedures visible: $COUNT"
[ "${COUNT//[^0-9]/}" -ge 1 ] 2>/dev/null || die "no target procedures found — restore looks wrong"
log "done ✓"
