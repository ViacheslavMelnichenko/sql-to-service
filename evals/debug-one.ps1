# Diagnose a failing live run cheaply: ONE proc, with raw claude/gate capture on.
#
# Run from a PowerShell window YOU opened (not a Claude Code session - the Foundry
# key is scrubbed from subprocesses Claude Code spawns).
#
#   cd C:\projects\sql-to-service
#   powershell -ExecutionPolicy Bypass -File evals\debug-one.ps1
#
# run-001 came back 0/3 with 0 tokens / 0 turns / null snapshot, i.e. claude -p
# produced no turns and the harness discarded the raw output. This drives ONE proc
# with EVAL_DEBUG=1 so every attempt's raw claude output and gate output land in
# evals\results\debug\ for inspection. ASCII ONLY (see run-live.ps1 header).

$ErrorActionPreference = "Continue"
$model = if ($env:EVAL_MODEL) { $env:EVAL_MODEL } else { "claude-opus-4-8-gateway" }
Set-Location (Split-Path $PSScriptRoot -Parent)
Write-Host "[dbg] repo: $(Get-Location)" -ForegroundColor Cyan

if ([string]::IsNullOrEmpty($env:ANTHROPIC_FOUNDRY_API_KEY)) {
    Write-Host "[dbg] ANTHROPIC_FOUNDRY_API_KEY is EMPTY - open a plain PowerShell." -ForegroundColor Red
    exit 1
}
Write-Host "[dbg] Foundry key present." -ForegroundColor Green

# One raw claude call, printed verbatim, so we see EXACTLY what the harness saw.
Write-Host "[dbg] raw claude -p probe (verbatim output follows):" -ForegroundColor Cyan
& claude -p --output-format json --model $model 'Reply with the single word: ok'
Write-Host ""
Write-Host "[dbg] --- end raw probe (exit $LASTEXITCODE) ---" -ForegroundColor Cyan

# Now one proc through the harness with capture on.
$env:EVAL_LIVE_OK = "1"
$env:EVAL_DEBUG = "1"
Write-Host "[dbg] driving ONE proc (Website.SearchForCustomers) with capture on ..." -ForegroundColor Yellow
& py evals/harness.py --run-id debug-one --procs Website.SearchForCustomers

Write-Host ""
Write-Host "[dbg] capture written under evals\results\debug\. Files:" -ForegroundColor Green
Get-ChildItem evals\results\debug\ -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      $($_.Name)" }
Write-Host "[dbg] paste evals\results\debug\*.attempt1.claude.txt and .gate.txt to Claude." -ForegroundColor Green
