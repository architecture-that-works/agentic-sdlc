#Requires -Version 7.0
<#
.SYNOPSIS
    Verify the harness environment configuration before starting a managed session.

.DESCRIPTION
    Checks that the key harness prerequisites are satisfied:
      1. .devcontainer/devcontainer.json exists and is valid JSON
      2. .claude/settings.json (if present) is valid JSON
      3. uv is available on PATH
      4. pyproject.toml is present (project root check)

    Idempotent: read-only — does not mutate project state. Safe to run multiple times.
    Run before provisioning a Dev Container or starting a PGE session.

.EXAMPLE
    pwsh .agents/skills/harness/scripts/verify-settings.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$failed = $false

# ── 1. Project root check ─────────────────────────────────────────────────────

if (-not (Test-Path 'pyproject.toml')) {
    Write-Warning "[BLOCK] pyproject.toml not found. Run this script from the project root."
    $failed = $true
} else {
    Write-Host "[OK] pyproject.toml found."
}

# ── 2. uv toolchain ───────────────────────────────────────────────────────────

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Warning "[WARN] uv not found on PATH. Install via: curl -LsSf https://astral.sh/uv/install.sh | sh"
    Write-Warning "       Without uv, the harness cannot run tests or install dependencies."
} else {
    Write-Host "[OK] uv is available: $(uv --version 2>&1)"
}

# ── 3. devcontainer.json ──────────────────────────────────────────────────────

$devcontainerPath = Join-Path (Get-Location) '.devcontainer' 'devcontainer.json'

if (-not (Test-Path $devcontainerPath)) {
    Write-Warning "[WARN] .devcontainer/devcontainer.json not found."
    Write-Warning "       Without a Dev Container, harness environments are not reproducible."
    Write-Warning "       See harness/REFERENCE.md for the standard devcontainer.json shape."
} else {
    try {
        Get-Content $devcontainerPath -Raw | ConvertFrom-Json | Out-Null
        Write-Host "[OK] .devcontainer/devcontainer.json is valid JSON."
    } catch {
        Write-Warning "[BLOCK] .devcontainer/devcontainer.json is not valid JSON: $_"
        $failed = $true
    }
}

# ── 4. Claude Code project settings (optional) ────────────────────────────────

$settingsPath = Join-Path (Get-Location) '.claude' 'settings.json'

if (Test-Path $settingsPath) {
    try {
        Get-Content $settingsPath -Raw | ConvertFrom-Json | Out-Null
        Write-Host "[OK] .claude/settings.json is valid JSON."
    } catch {
        Write-Warning "[BLOCK] .claude/settings.json is not valid JSON: $_"
        $failed = $true
    }
} else {
    Write-Host "[INFO] .claude/settings.json not found — using default Claude Code settings."
}

# ── Result ────────────────────────────────────────────────────────────────────

if ($failed) {
    Write-Error "`n[FAIL] Harness verification failed. Resolve issues above before starting a session."
    exit 1
}

Write-Host "`n[PASS] Harness environment verification complete. Ready to start a managed session."
exit 0
