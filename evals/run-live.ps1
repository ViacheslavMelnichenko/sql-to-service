# Local live-eval runner for Windows PowerShell (B.3).
#
# Run this from a PowerShell window YOU opened (Start -> PowerShell), NOT from
# inside a Claude Code session: CLAUDE_CODE_SUBPROCESS_ENV_SCRUB strips the
# Foundry API key from subprocesses Claude Code spawns, and the harness would
# then fail to authenticate. From your own shell the key is present.
#
#   cd C:\projects\sql-to-service
#   powershell -ExecutionPolicy Bypass -File evals\run-live.ps1
#
# k=3 (PREREGISTRATION.md). Each invocation produces ONE independent sample -> a
# separate evals\results\run-001.sample-0N.json (N auto-detected as the next free
# number, so a re-run never clobbers an earlier sample). After the 3rd sample,
# aggregate them into the distribution run-001.json:
#
#   powershell -ExecutionPolicy Bypass -File evals\run-live.ps1     # sample 2, then 3
#   py evals\aggregate.py --expect-k 3                              # -> run-001.json
#
# Force a specific sample number with -Sample N (e.g. to redo a bad sample).
#
# It: (1) checks the Foundry key is visible, (2) probes headless auth before
# spending any budget, (3) brings the two engines up, (4) waits for health,
# (5) ensures pymongo, (6) runs the LIVE harness -> the next sample file.
#
# ASCII ONLY. Windows PowerShell 5.1 reads a no-BOM script as the ANSI codepage,
# so any em-dash or smart-quote becomes garbage bytes that break the parser in
# unrelated places. Keep every character in this file plain ASCII.

param(
    [int]$Sample = 0   # 0 = auto-detect the next free sample number
)

$ErrorActionPreference = "Stop"
$model = if ($env:EVAL_MODEL) { $env:EVAL_MODEL } else { "claude-opus-4-8-gateway" }

# Move to the repo root (this script lives in evals\).
Set-Location (Split-Path $PSScriptRoot -Parent)
Write-Host "[run] repo: $(Get-Location)" -ForegroundColor Cyan

# --- 1. Foundry key present? -------------------------------------------------
if ([string]::IsNullOrEmpty($env:ANTHROPIC_FOUNDRY_API_KEY)) {
    Write-Host "[run] ANTHROPIC_FOUNDRY_API_KEY is EMPTY in this shell." -ForegroundColor Red
    Write-Host "      The live run cannot authenticate. Two possibilities:" -ForegroundColor Red
    Write-Host "      - You are inside a Claude Code session (key scrubbed) -> open a plain PowerShell." -ForegroundColor Yellow
    Write-Host "      - The key is injected only into Claude Code, not your user env -> tell Claude." -ForegroundColor Yellow
    exit 1
}
Write-Host "[run] Foundry key present." -ForegroundColor Green

# --- 2. claude on PATH? ------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "[run] 'claude' not on PATH - cannot run live." -ForegroundColor Red
    exit 1
}

# --- 3. Auth probe (cheap: one word, fail fast before any real spend) --------
Write-Host "[run] probing headless auth with --model $model ..." -ForegroundColor Cyan
$probe = & claude -p --output-format json --model $model 'Reply with the single word: ok' 2>&1 | Out-String
if ($probe -match '"is_error"\s*:\s*true' -or $probe -match 'authentication failed' -or $probe -match 'API Error') {
    Write-Host "[run] AUTH PROBE FAILED - not spending budget. First 20 lines:" -ForegroundColor Red
    ($probe -split "`n" | Select-Object -First 20) | ForEach-Object { Write-Host "      $_" }
    exit 1
}
Write-Host "[run] auth probe ok." -ForegroundColor Green

# --- 4. Engines up + healthy -------------------------------------------------
# Native tools (docker/pip) write progress to stderr; under ErrorActionPreference
# Stop that stderr is treated as a terminating error even on success. Drop to
# Continue for this best-effort section.
if (-not (Test-Path ".env")) {
    Write-Host "[run] no .env - copy .env.example to .env and set the SA password first." -ForegroundColor Red
    exit 1
}
$ErrorActionPreference = "Continue"
Write-Host "[run] bringing up mssql + mongo (no-op if already running) ..." -ForegroundColor Cyan
docker compose up -d mssql mongo 2>&1 | Out-Host

# Wait on TCP reachability of the mapped ports rather than 'docker inspect
# --format' with a Go template - PowerShell's parser reads a literal double
# brace as an array-index expression and fails to compile the whole script.
$ports = @{ "mssql" = 11433; "mongo" = 37017 }
$deadline = (Get-Date).AddSeconds(240)
foreach ($svc in $ports.Keys) {
    $port = $ports[$svc]
    Write-Host "[run] waiting for $svc on port $port ..." -ForegroundColor Cyan
    while ($true) {
        $ok = (Test-NetConnection -ComputerName localhost -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded
        if ($ok) { Write-Host "[run] $svc reachable." -ForegroundColor Green; break }
        if ((Get-Date) -gt $deadline) {
            Write-Host "[run] $svc port $port not reachable in time." -ForegroundColor Red
            exit 1
        }
        Start-Sleep -Seconds 5
    }
}

# --- 5. pymongo (seed loader) ------------------------------------------------
Write-Host "[run] ensuring pymongo ..." -ForegroundColor Cyan
& py -m pip install --quiet pymongo 2>&1 | Out-Host

# --- 6. LIVE harness ---------------------------------------------------------
# Pick the sample number: explicit -Sample wins; otherwise the next free NN.
if ($Sample -lt 1) {
    $existing = Get-ChildItem "evals\results" -Filter "run-001.sample-*.json" -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -match 'sample-(\d+)\.json$') { [int]$Matches[1] } }
    $Sample = if ($existing) { ([int]($existing | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
}
$sampleId = "run-001.sample-{0:D2}" -f $Sample
$sampleFile = "evals\results\$sampleId.json"

Write-Host "[run] LIVE RUN starting (sample $Sample of k=3). Real API budget; drives the agent through the gate." -ForegroundColor Yellow
Write-Host "      This can take tens of minutes. Writes $sampleFile." -ForegroundColor Yellow
$env:EVAL_LIVE_OK = "1"
& py evals/harness.py --run-id $sampleId
$code = $LASTEXITCODE

Write-Host ""
if (Test-Path $sampleFile) {
    Write-Host "[run] DONE. Sample written to $sampleFile" -ForegroundColor Green
    $n = (Get-ChildItem "evals\results" -Filter "run-001.sample-*.json").Count
    if ($n -ge 3) {
        Write-Host "[run] $n samples present. Aggregate now:  py evals\aggregate.py --expect-k 3" -ForegroundColor Green
    } else {
        Write-Host "[run] $n of 3 samples done. Re-run this script for the next one." -ForegroundColor Cyan
    }
    Write-Host "      Then paste run-001.json to Claude (or say done) to finish B.3." -ForegroundColor Green
} else {
    Write-Host "[run] harness exited ($code) but no $sampleFile was written - check the output above." -ForegroundColor Red
}
exit $code
