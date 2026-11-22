#Requires -Version 7.0
<#
.SYNOPSIS
    The full test run: pytest with the coverage gate for src/, then Pester over the
    orchestrator's journeys with the line coverage it measures — one exit code.

.DESCRIPTION
    The one command that runs every test. The `test` job of checks.yml, the implement
    stage's independent verification and ship's local CI all call it.

      1. Pester 5 must be available; when it is not, the command stops with the line
         that installs it (it never installs anything itself).
      2. uv run pytest --cov=src --cov-report=term-missing --cov-fail-under=80
      3. One Pester run over tests/journeys/: every journey first, the state-machine
         report (StateMachine.Tests.ps1) last, so the report reads the transitions every
         journey caused. Line coverage is measured over .github/orchestrator/ and
         reported, not gated.

    It ends with one summary line per runner — passed or failed, and how long it took;
    Pester's line also gives its coverage — and exits non-zero when either runner failed.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/test.ps1
#>
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath

# ── Pester 5 ──────────────────────────────────────────────────────────────────
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host 'Pester 5 is not installed. Install it, then run this command again:' -ForegroundColor Red
    Write-Host '  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force'
    exit 1
}

Push-Location -LiteralPath $root
try {
    # ── pytest ────────────────────────────────────────────────────────────────
    Write-Host '━━━ pytest' -ForegroundColor Cyan
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    & uv run pytest --cov=src --cov-report=term-missing --cov-fail-under=80
    $pytestExit = $LASTEXITCODE
    $pytestTime = $clock.Elapsed.TotalSeconds

    # ── Pester ────────────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '━━━ Pester' -ForegroundColor Cyan
    Import-Module $pester.Path -Force
    $journeys = Join-Path $root 'tests/journeys'
    $report   = Join-Path $journeys 'StateMachine.Tests.ps1'
    $files    = @(Get-ChildItem -LiteralPath $journeys -Filter '*.Tests.ps1' -File |
        Where-Object { $_.FullName -ne $report } | Sort-Object Name | ForEach-Object { $_.FullName }) + $report

    $coverageFile = Join-Path ([System.IO.Path]::GetTempPath()) "pester-coverage-$PID.xml"
    $config = New-PesterConfiguration
    $config.Run.Container            = @($files | ForEach-Object { New-PesterContainer -Path $_ })
    $config.Run.PassThru             = $true
    $config.Output.Verbosity         = 'Normal'
    $config.CodeCoverage.Enabled     = $true
    $config.CodeCoverage.Path        = @(Get-ChildItem -LiteralPath (Join-Path $root '.github/orchestrator') -Recurse -File -Include '*.ps1', '*.psm1' |
        ForEach-Object { $_.FullName })
    $config.CodeCoverage.OutputPath  = $coverageFile
    $config.CodeCoverage.CoveragePercentTarget = 0   # reported, not gated

    # A fresh record of the transitions the journeys cause, read by the report.
    $global:OrchestratorJourneyTransitions = $null
    $clock.Restart()
    $result = Invoke-Pester -Configuration $config
    $pesterTime = $clock.Elapsed.TotalSeconds
    Remove-Item -LiteralPath $coverageFile -ErrorAction SilentlyContinue
    $pesterPassed = $result -and $result.Result -eq 'Passed' -and $result.FailedCount -eq 0

    # Line coverage: of the lines holding a command, those where one ran.
    $coverage = 'no coverage measured'
    if ($result -and $result.CodeCoverage) {
        $key  = { "$($_.File)|$($_.Line)" }
        $hit  = @($result.CodeCoverage.CommandsExecuted | ForEach-Object $key | Sort-Object -Unique)
        $all  = @(@($result.CodeCoverage.CommandsExecuted) + @($result.CodeCoverage.CommandsMissed) | ForEach-Object $key | Sort-Object -Unique)
        if ($all.Count -gt 0) {
            $coverage = 'line coverage {0:N1}% of .github/orchestrator/ ({1} of {2} lines)' -f (100 * $hit.Count / $all.Count), $hit.Count, $all.Count
        }
    }
} finally {
    Pop-Location
}

# ── Summary ───────────────────────────────────────────────────────────────────
$verdict = { param($ok) if ($ok) { 'passed' } else { 'FAILED' } }
Write-Host ''
Write-Host 'Test summary'
Write-Output ('pytest  {0}  {1:N1}s' -f (& $verdict ($pytestExit -eq 0)), $pytestTime)
Write-Output ('Pester  {0}  {1:N1}s  {2}' -f (& $verdict $pesterPassed), $pesterTime, $coverage)
if ($pytestExit -ne 0 -or -not $pesterPassed) { exit 1 }
exit 0
