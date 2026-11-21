#Requires -Version 7.0
<#
.SYNOPSIS
    Guards the orchestrator's public API: code outside .github/orchestrator/ calls only the
    functions Orchestrator.psd1 exports, and every export has an outside caller.

.DESCRIPTION
    Orchestrator.psd1 FunctionsToExport is the module boundary. Callers are the workflows,
    the task runnables in .github/tasks/ and the skill scripts. A caller that names a private
    function breaks when the function is renamed; an export nobody calls widens the API for
    nothing. Exits 0 when both hold, 1 with one line per violation otherwise.

.EXAMPLE
    pwsh .github/checks/check-orchestrator-api.ps1
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath

# 1. Get exports
$psd1 = Join-Path $RepoRoot ".github/orchestrator/Orchestrator.psd1"
$manifest = Import-PowerShellDataFile -Path $psd1
$exports = $manifest.FunctionsToExport
if (-not $exports) {
    Write-Host "❌ Could not parse FunctionsToExport from Orchestrator.psd1 — restore its explicit FunctionsToExport list." -ForegroundColor Red
    exit 1
}

# 2. Get all functions in the module
$psm1Files = @(
    Get-ChildItem -Path (Join-Path $RepoRoot ".github/orchestrator") -Filter "*.psm1" -File
    Get-ChildItem -Path (Join-Path $RepoRoot ".github/orchestrator") -Filter "*.ps1" -Recurse -File
)
$allFunctions = @()
foreach ($f in $psm1Files) {
    $content = Get-Content $f.FullName -Raw
    $defined = [regex]::Matches($content, '(?mi)^\s*function\s+([A-Za-z0-9\-]+)\s*(?:\{|\()')
    foreach ($m in $defined) {
        $allFunctions += $m.Groups[1].Value
    }
}
$allFunctions = $allFunctions | Select-Object -Unique
$privateFunctions = $allFunctions | Where-Object { $exports -notcontains $_ }

# 3. Check external callers
# Includes workflows, tasks and skill scripts.
$callerFiles = @(
    Get-ChildItem -Path (Join-Path $RepoRoot ".github/workflows") -Filter "*.yml" -File
    Get-ChildItem -Path (Join-Path $RepoRoot ".github/tasks") -Filter "*.ps1" -File
    Get-ChildItem -Path (Join-Path $RepoRoot ".agents/skills") -Filter "*.ps1" -Recurse -File
)

$calledExports = @{}
$failures = 0

foreach ($f in $callerFiles) {
    if (-not (Test-Path $f.FullName)) { continue }
    $content = Get-Content $f.FullName -Raw
    
    foreach ($exp in $exports) {
        if ($content -match "\b$exp\b") {
            $calledExports[$exp] = $true
        }
    }

    foreach ($priv in $privateFunctions) {
        if ($content -match "\b$priv\b") {
            Write-Host "❌ $($f.Name) calls private orchestrator function '$priv' — call an exported function instead, or add '$priv' to FunctionsToExport in Orchestrator.psd1." -ForegroundColor Red
            $failures++
        }
    }
}

foreach ($exp in $exports) {
    if (-not $calledExports.ContainsKey($exp)) {
        Write-Host "❌ '$exp' is exported but nothing outside the orchestrator calls it — remove it from FunctionsToExport in Orchestrator.psd1." -ForegroundColor Red
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Host "❌ $failures orchestrator API violation(s) found." -ForegroundColor Red
    exit 1
}

Write-Host "✅ Orchestrator API contract holds: all exports are used, no private functions are called externally." -ForegroundColor Green
exit 0
