# Local live-eval runner for Windows PowerShell (B.3).
#
# Run this from a PowerShell window YOU opened (Start -> PowerShell) — NOT from
# inside a Claude Code session, because CLAUDE_CODE_SUBPROCESS_ENV_SCRUB strips the
# Foundry API key from subprocesses Claude Code spawns, and the harness would then
# fail to authenticate. From your own shell the key is present and inherited.
#
#   cd C:\projects\sql-to-service
#   powershell -ExecutionPolicy Bypass -File evals\run-live.ps1
#
# It: (1) checks the Foundry key is visible, (2) probes headless auth before spending
# any budget, (3) brings the two engines up, (4) waits for health, (5) ensures
# pymongo, (6) runs the LIVE harness, which writes evals\results\run-001.json.

$ErrorActionPreference = "Stop"
$model = if ($env:EVAL_MODEL) { $env:EVAL_MODEL } else { "claude-opus-4-8-gateway" }

# Move to the repo root (this script lives in evals\).
Set-Location (Split-Path $PSScriptRoot -Parent)
Write-Host "[run] repo: $(Get-Location)" -ForegroundColor Cyan

# --- 1. Foundry key present? -------------------------------------------------------
if ([string]::IsNullOrEmpty($env:ANTHROPIC_FOUNDRY_API_KEY)) {
    Write-Host "[run] ANTHROPIC_FOUNDRY_API_KEY is EMPTY in this shell." -ForegroundColor Red
    Write-Host "      The live run cannot authenticate. Two possibilities:" -ForegroundColor Red
    Write-Host "      - You are inside a Claude Code session (the key is scrubbed) -> open a plain PowerShell." -ForegroundColor Yellow
    Write-Host "      - The key is injected only into Claude Code, not your user env -> tell Claude, we'll trace it." -ForegroundColor Yellow
    exit 1
}
Write-Host "[run] Foundry key present." -ForegroundColor Green

# --- 2. claude on PATH? ------------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "[run] 'claude' not on PATH — cannot run live." -ForegroundColor Red
    exit 1
}

# --- 3. Auth probe (cheap: one word, fail fast before any real spend) --------------
Write-Host "[run] probing headless auth with --model $model ..." -ForegroundColor Cyan
$probe = & claude -p --output-format json --model $model 'Reply with the single word: ok' 2>&1 | Out-String
if ($probe -match '"is_error"\s*:\s*true' -or $probe -match 'authentication failed' -or $probe -match 'API Error') {
    Write-Host "[run] AUTH PROBE FAILED — not spending budget. First 20 lines:" -ForegroundColor Red
    ($probe -split "`n" | Select-Object -First 20) | ForEach-Object { Write-Host "      $_" }
    exit 1
}
Write-Host "[run] auth probe ok." -ForegroundColor Green

# --- 4. Engines up + healthy -------------------------------------------------------
# Native tools (docker/pip) write progress to stderr; under -ErrorActionPreference
# Stop that stderr is treated as a terminating error even on success. Drop to
# Continue for this best-effort section so a healthy engine is never mistaken for a
# failure, and swallow stderr explicitly.
if (-not (Test-Path ".env")) {
    Write-Host "[run] no .env — copy .env.example to .env and set the SA password first." -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Continue"
Write-Host "[run] bringing up mssql + mongo (no-op if already running) ..." -ForegroundColor Cyan
docker compose up -d mssql mongo 2>&1 | Out-Host

$deadline = (Get-Date).AddSeconds(240)
foreach ($svc in @("mssql", "mongo")) {
    Write-Host "[run] waiting for $svc to be healthy ..." -ForegroundColor Cyan
    while ($true) {
        $cid = (docker compose ps -q $svc 2>$null | Out-String).Trim()
        $status = ""
        if ($cid) { $status = (docker inspect -f '{{.State.Health.Status}}' $cid 2>$null | Out-String).Trim() }
        if ($status -eq "healthy") { Write-Host "[run] $svc healthy." -ForegroundColor Green; break }
        if ((Get-Date) -gt $deadline) {
            Write-Host "[run] $svc never became healthy (status='$status')." -ForegroundColor Red
            docker compose logs $svc 2>&1 | Select-Object -Last 40 | Out-Host
            exit 1
        }
        Start-Sleep -Seconds 5
    }
}

# --- 5. pymongo (seed loader) ------------------------------------------------------
Write-Host "[run] ensuring pymongo ..." -ForegroundColor Cyan
& py -m pip install --quiet pymongo 2>&1 | Out-Host

# --- 6. LIVE harness ---------------------------------------------------------------
Write-Host "[run] LIVE RUN starting. Real API budget; drives the agent through the gate." -ForegroundColor Yellow
Write-Host "      This can take tens of minutes. Writes evals\results\run-001.json." -ForegroundColor Yellow
$env:EVAL_LIVE_OK = "1"
& py evals/harness.py --run-id run-001
$code = $LASTEXITCODE

Write-Host ""
if (Test-Path "evals\results\run-001.json") {
    Write-Host "[run] DONE. Result written to evals\results\run-001.json" -ForegroundColor Green
    Write-Host "      Paste that file to Claude (or say 'done') to finish B.3." -ForegroundColor Green
} else {
    Write-Host "[run] harness exited ($code) but no run-001.json was written — check the output above." -ForegroundColor Red
}
exit $code
