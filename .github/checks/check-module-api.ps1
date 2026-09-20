$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath

# 1. Get exports
$psd1 = Join-Path $RepoRoot ".github/orchestrator/Orchestrator.psd1"
$manifest = Import-PowerShellDataFile -Path $psd1
$exports = $manifest.FunctionsToExport
if (-not $exports) {
    Write-Host "❌ Could not parse FunctionsToExport from Orchestrator.psd1" -ForegroundColor Red
    exit 1
}

# 2. Get all functions in the module
$psm1Files = @(
    Get-ChildItem -Path (Join-Path $RepoRoot ".github/orchestrator") -Filter "*.psm1" -File
    Get-ChildItem -Path (Join-Path $RepoRoot ".github/orchestrator") -Filter "*.ps1" -Recurse -File
    # _grill.ps1 is dot-sourced by the orchestrator, so it's part of the module's implementation
    Get-ChildItem -Path (Join-Path $RepoRoot ".agents/skills/refine/scripts/_grill.ps1") -File -ErrorAction SilentlyContinue
)
$allFunctions = @()
foreach ($f in $psm1Files) {
    $content = Get-Content $f.FullName -Raw
    $matches = [regex]::Matches($content, '(?mi)^\s*function\s+([A-Za-z0-9\-]+)\s*(?:\{|\()')
    foreach ($m in $matches) {
        $allFunctions += $m.Groups[1].Value
    }
}
$allFunctions = $allFunctions | Select-Object -Unique
$privateFunctions = $allFunctions | Where-Object { $exports -notcontains $_ }

# 3. Check external callers
# Includes workflows, tasks, skills (excluding the module's own _grill.ps1), and tests (since tests act as API consumers)
$callerFiles = @(
    Get-ChildItem -Path (Join-Path $RepoRoot ".github/workflows") -Filter "*.yml" -File
    Get-ChildItem -Path (Join-Path $RepoRoot ".github/scripts/tasks") -Filter "*.ps1" -File
    Get-ChildItem -Path (Join-Path $RepoRoot ".agents/skills") -Filter "*.ps1" -Recurse -File | Where-Object { $_.Name -ne '_grill.ps1' }
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
            Write-Host "❌ Module boundary violation: External file $($f.Name) calls private module function '$priv'" -ForegroundColor Red
            $failures++
        }
    }
}

foreach ($exp in $exports) {
    if (-not $calledExports.ContainsKey($exp)) {
        Write-Host "❌ Dead export: Function '$exp' is exported but never called by any external file." -ForegroundColor Red
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Host "❌ $failures module API violations found." -ForegroundColor Red
    exit 1
}

Write-Host "✅ Module API contract holds: all exports are used, no private functions are called externally." -ForegroundColor Green
exit 0
