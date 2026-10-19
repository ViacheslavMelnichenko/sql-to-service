#!/usr/bin/env bash
# Feature-card gate (ADR-0008) — STANDALONE. It is deliberately NOT called from
# gates/verify.sh: the feature cards are observability, not an oracle, so they must
# have zero authority over the correctness verdict. This gate proves two things —
# that the cards are honest (deterministic, in sync with the demo, taxonomy intact)
# and that they are powerless (no file in the correctness loop reads them).
#
# Unlike verify.sh (stdlib-only, no model), this gate needs sqlglot to regenerate
# and compare — it is a maintenance/CI gate for the cards, not part of the trust
# chain that reproduces the published numbers. It reports; it does not mutate the
# committed artifact (it restores any file it regenerates).
#
#   bash gates/features-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;34m[features-check]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[features-check] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '\033[1;32m[features-check] PASS:\033[0m %s\n' "$*"; }

PY="${PYTHON:-py}"
command -v "$PY" >/dev/null 2>&1 || PY=python

# This gate needs sqlglot (it regenerates the cards). verify.sh does not — that is
# the whole point of keeping them separate.
"$PY" -c "import sqlglot" 2>/dev/null || die \
  "sqlglot not installed — this gate regenerates the cards. Run: $PY -m pip install -r corpus/requirements.txt"

FEATURES_DIR="corpus/features"
DEMO_DATA="demo/features-data.js"

# --- Check 1: presence & shape ------------------------------------------------------
log "check 1/5 — presence & shape"
"$PY" - "$ROOT" <<'PYEOF' || die "presence/shape check failed (see above)"
import json, os, sys
root = sys.argv[1]
procs_dir = os.path.join(root, "corpus", "procs")
feats_dir = os.path.join(root, "corpus", "features")
procs = sorted(f[:-4] for f in os.listdir(procs_dir) if f.endswith(".sql"))
if not procs:
    print("  no procs found under corpus/procs/"); sys.exit(1)
bad = 0
for full in procs:
    short = full.split(".", 1)[-1]
    path = os.path.join(feats_dir, short + ".features.json")
    if not os.path.isfile(path):
        print(f"  MISSING card: {short}.features.json"); bad += 1; continue
    try:
        card = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        print(f"  INVALID JSON {short}: {e}"); bad += 1; continue
    for key in ("schema_version", "sqlglot_version", "proc", "features"):
        if key not in card:
            print(f"  {short}: missing '{key}'"); bad += 1
print(f"  {len(procs)} procs, {len(procs) - bad} valid cards")
sys.exit(1 if bad else 0)
PYEOF
ok "all cards present, valid JSON, versioned"

# --- Checks 2 & 3: determinism + demo sync (regenerate, diff, restore) ---------------
# Back up the committed artifacts, regenerate in place, diff, then RESTORE — so the
# gate never leaves the working tree mutated even on a clean pass.
TMP="$(mktemp -d)"
trap 'cp -f "$TMP/backup/"*.features.json "$FEATURES_DIR/" 2>/dev/null; cp -f "$TMP/features-data.js" "$DEMO_DATA" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/backup"
cp -f "$FEATURES_DIR"/*.features.json "$TMP/backup/"
cp -f "$DEMO_DATA" "$TMP/features-data.js"

log "check 2/5 — determinism (re-run extractor, expect byte-identical)"
# The extractor ALWAYS writes LF; any CR here is a git autocrlf checkout artifact,
# not an extractor difference — so --strip-trailing-cr compares the meaningful bytes
# (real content drift in a stale/edited card still reds the gate).
"$PY" corpus/extract-features.py --all >/dev/null 2>&1 || die "extractor re-run failed"
if diff -r --strip-trailing-cr "$TMP/backup" "$FEATURES_DIR" >"$TMP/cards.diff" 2>&1; then
  ok "cards byte-identical on re-run"
else
  cat "$TMP/cards.diff" >&2
  die "cards drifted on re-run — extractor not deterministic, or committed cards stale (regenerate)"
fi

log "check 3/5 — demo sync (re-emit features-data.js, expect byte-identical)"
"$PY" corpus/extract-features.py --emit-demo >/dev/null 2>&1 || die "demo emit failed"
if diff --strip-trailing-cr "$TMP/features-data.js" "$DEMO_DATA" >"$TMP/demo.diff" 2>&1; then
  ok "demo/features-data.js in sync with the cards"
else
  cat "$TMP/demo.diff" >&2
  die "demo/features-data.js out of sync — re-run: $PY corpus/extract-features.py --emit-demo"
fi

# --- Check 4: taxonomy (teeth) ------------------------------------------------------
log "check 4/5 — taxonomy (every kind catalogued; every skill maps to a real dir)"
"$PY" - "$ROOT" <<'PYEOF' || die "taxonomy check failed (see above)"
import importlib.util, json, os, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "ef", os.path.join(root, "corpus", "extract-features.py"))
ef = importlib.util.module_from_spec(spec); spec.loader.exec_module(ef)
cat = ef.KIND_CATALOGUE
feats_dir = os.path.join(root, "corpus", "features")
skills_dir = os.path.join(root, ".claude", "skills")
bad = 0
# every kind used by a card must be catalogued
for f in sorted(os.listdir(feats_dir)):
    if not f.endswith(".features.json"):
        continue
    card = json.load(open(os.path.join(feats_dir, f), encoding="utf-8"))
    for feat in card["features"]:
        if feat["kind"] not in cat:
            print(f"  {f}: kind '{feat['kind']}' not in KIND_CATALOGUE"); bad += 1
# every catalogue skill must be a real skills dir (or the '-' sentinel)
for kind, meta in sorted(cat.items()):
    skill = meta["skill"]
    if skill == "-":
        continue
    if not os.path.isdir(os.path.join(skills_dir, skill)):
        print(f"  catalogue kind '{kind}' -> skill '{skill}' has no .claude/skills/{skill}/ dir")
        bad += 1
print(f"  {len(cat)} catalogue kinds checked against .claude/skills/")
sys.exit(1 if bad else 0)
PYEOF
ok "taxonomy intact — no skill<->extractor drift"

# --- Check 5: out-of-authority proof (teeth, ADR-0006 style) ------------------------
log "check 5/5 — out-of-authority (no correctness-loop file references corpus/features)"
# The correctness loop is the JUDGE and everything that enforces its verdict in-loop:
# verify.sh / differential.sh (the gate itself), the Stop and PostToolUse hooks that
# run the gate during a conversion turn, and every pipeline subagent. If ANY of these
# read a card, the card would have a say in the verdict — so none may reference it.
LOOP_FILES=(gates/verify.sh gates/differential.sh \
  .claude/hooks/stop-differential.sh .claude/hooks/post-write-build.sh)
while IFS= read -r a; do LOOP_FILES+=("$a"); done < <(ls .claude/agents/*.md 2>/dev/null || true)
offenders=""
for f in "${LOOP_FILES[@]}"; do
  [ -f "$f" ] || continue
  if grep -n "corpus/features" "$f" >/dev/null 2>&1; then
    offenders="$offenders $f"
  fi
done
if [ -n "$offenders" ]; then
  die "correctness-loop file(s) reference corpus/features — cards would have authority:$offenders"
fi
ok "no correctness-loop file reads corpus/features — cards have zero verdict authority"

log "all 5 checks passed"
