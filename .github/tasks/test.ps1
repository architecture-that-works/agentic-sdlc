#Requires -Version 7.0
<#
.SYNOPSIS
    The full test run: pytest with the coverage gate for src/, then one Pester run over
    the orchestrator's decision tables and journeys — one exit code.

.DESCRIPTION
    The one command that runs every test. The `test` job of checks.yml, the implement
    stage's independent verification and ship's local CI all call it.

      1. When tests/decisions/ or tests/journeys/ exists, Pester 5 must be available;
         when it is not, the command stops with the line that installs it (it never
         installs anything itself). A generated project carries neither folder, so
         there the command runs pytest alone and says Pester was not run.
      2. uv run pytest --cov=src --cov-report=term-missing --cov-fail-under=80
      3. One Pester run: every decision table (tests/decisions/) and every journey
         (tests/journeys/), sorted by name, then the state-machine report
         (tests/journeys/StateMachine.Tests.ps1) last, so the report reads the
         transitions every one of them caused. Line coverage is measured over
         .github/orchestrator/ and reported, not gated.

    It prints the Pester version it runs on, before the run and on Pester's summary
    line, so a difference between a machine and the runner shows in the output. It ends
    with one summary line per runner — passed or failed, and how long it took — and
    exits non-zero when either runner failed.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/test.ps1
#>
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath

# ── Pester 5, when there are Pester tests ────────────────────────────────────
$journeys  = Join-Path $root 'tests/journeys'
$decisions = Join-Path $root 'tests/decisions'
$report    = Join-Path $journeys 'StateMachine.Tests.ps1'
$pesterDirs = @($decisions, $journeys | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
$runPester  = $pesterDirs.Count -gt 0
$pester = $null
if ($runPester) {
    $pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0' } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester) {
        Write-Host 'Pester 5 is not installed. Install it, then run this command again:' -ForegroundColor Red
        Write-Host '  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force'
        exit 1
    }
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
    $pesterPassed = $true
    $pesterTime   = 0
    $coverage     = ''
    if ($runPester) {
        Write-Host ''
        Write-Host "━━━ Pester $($pester.Version)" -ForegroundColor Cyan
        Import-Module $pester.Path -Force
        $tables = @($pesterDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.Tests.ps1' -File } |
            Where-Object { $_.FullName -ne $report } | Sort-Object Name | ForEach-Object { $_.FullName })
        $files  = $tables + @($report | Where-Object { Test-Path -LiteralPath $_ })

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

        # A fresh record of the transitions the tables and journeys cause, read by the report.
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
    }
} finally {
    Pop-Location
}

# ── Summary ───────────────────────────────────────────────────────────────────
$verdict = { param($ok) if ($ok) { 'passed' } else { 'FAILED' } }
Write-Host ''
Write-Host 'Test summary'
Write-Output ('pytest  {0}  {1:N1}s' -f (& $verdict ($pytestExit -eq 0)), $pytestTime)
if ($runPester) {
    Write-Output ('Pester  {0}  {1:N1}s  Pester {2}  {3}' -f (& $verdict $pesterPassed), $pesterTime, $pester.Version, $coverage)
} else {
    Write-Output 'Pester  not run — no tests/decisions/ or tests/journeys/ in this project'
}
if ($pytestExit -ne 0 -or -not $pesterPassed) { exit 1 }
exit 0
