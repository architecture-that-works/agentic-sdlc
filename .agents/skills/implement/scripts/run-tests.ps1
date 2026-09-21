#Requires -Version 7.0
<#
.SYNOPSIS
    Idempotent test runner for the `implement` skill.

.DESCRIPTION
    Runs the full pytest suite via `uv run pytest`. Verifies the environment is ready
    before running (uv lock is up to date, pyproject.toml is present). Exits 0 if
    tests pass; exits non-zero if they fail or the environment is not ready.

    Idempotent: running this script multiple times produces the same result.
    It does not mutate project state — it only reads and runs.

.PARAMETER Filter
    Optional pytest -k filter expression. Defaults to empty (run all tests).

.PARAMETER NoCoverage
    Skip coverage reporting (faster for quick feedback loops).

.PARAMETER FailFast
    Stop after the first failure (-x). Enabled by default.

.EXAMPLE
    # Run all tests with coverage
    pwsh .agents/skills/implement/scripts/run-tests.ps1

    # Run only tests matching "order"
    pwsh .agents/skills/implement/scripts/run-tests.ps1 -Filter "order"

    # Run without coverage and without fail-fast
    pwsh .agents/skills/implement/scripts/run-tests.ps1 -NoCoverage -FailFast:$false
#>

[CmdletBinding()]
param(
    [string]$Filter     = '',
    [switch]$NoCoverage,
    [switch]$FailFast   = $true
)

$ErrorActionPreference = 'Stop'

# ── State verification (idempotent — read-only) ──────────────────────────────

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Error "uv is not installed or not on PATH. Install via: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
}

if (-not (Test-Path 'pyproject.toml')) {
    Write-Error "pyproject.toml not found. Run this script from the project root."
    exit 1
}

$lockCheck = uv lock --check 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warning "uv.lock is out of date. Run 'uv lock' to update it before running tests."
    Write-Warning $lockCheck
    exit 1
}

# ── Build pytest arguments ────────────────────────────────────────────────────

$pytestArgs = @('run', 'pytest')

if ($FailFast) {
    $pytestArgs += '-x'
}

if ($NoCoverage) {
    $pytestArgs += '--no-cov'
} else {
    $pytestArgs += @('--cov=src', '--cov-report=term-missing')
}

if ($Filter) {
    $pytestArgs += @('-k', $Filter)
}

# ── Run tests ─────────────────────────────────────────────────────────────────

Write-Host "Running: uv $($pytestArgs -join ' ')"
uv @pytestArgs
exit $LASTEXITCODE
