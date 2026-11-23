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
         (tests/journeys/), sorted by name, then the two reports last, so they read
         what every one of them did: the state-machine report
         (tests/journeys/StateMachine.Tests.ps1) checks the label transitions, the
         export-reach report (tests/journeys/ExportReach.Tests.ps1) that every
         exported function was reached. Line coverage is measured over
         .github/orchestrator/.

    The Pester run holds three gates:
      - Coverage floor: the run fails when the line coverage of .github/orchestrator/
        is below $CoverageFloor, set once below in this file.
      - Complete state machine: the state-machine report fails, naming it, for each
        designed transition (an AllowedFrom entry of $PipelineStates in
        .github/orchestrator/lib/Config.ps1) no table or journey exercised.
      - Time budget: the step of the `test` job in .github/workflows/checks.yml that
        runs this command stops at its timeout-minutes.
    None of them applies where Pester does not run (a generated project).

    It prints the Pester version it runs on, before the run and on Pester's summary
    line, so a difference between a machine and the runner shows in the output. It ends
    with one summary line per runner — passed or failed, and how long it took; for
    Pester also the measured line coverage and the floor — and exits non-zero when
    either runner failed or the coverage is below the floor.

.EXAMPLE
    pwsh -NoProfile -File .github/tasks/test.ps1
#>
param()

$ErrorActionPreference = 'Stop'

# The lowest line coverage of .github/orchestrator/ the Pester run accepts, in whole percent.
$CoverageFloor = 83

$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath

# ── Pester 5, when there are Pester tests ────────────────────────────────────
$journeys  = Join-Path $root 'tests/journeys'
$decisions = Join-Path $root 'tests/decisions'
$reports   = @('StateMachine.Tests.ps1', 'ExportReach.Tests.ps1' | ForEach-Object { Join-Path $journeys $_ })
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
    $covered      = $true
    $percent      = 0   # no coverage measured is below any floor
    if ($runPester) {
        Write-Host ''
        Write-Host "━━━ Pester $($pester.Version)" -ForegroundColor Cyan
        Import-Module $pester.Path -Force
        $tables = @($pesterDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.Tests.ps1' -File } |
            Where-Object { $_.FullName -notin $reports } | Sort-Object Name | ForEach-Object { $_.FullName })
        $files  = $tables + @($reports | Where-Object { Test-Path -LiteralPath $_ })

        $coverageFile = Join-Path ([System.IO.Path]::GetTempPath()) "pester-coverage-$PID.xml"
        $config = New-PesterConfiguration
        $config.Run.Container            = @($files | ForEach-Object { New-PesterContainer -Path $_ })
        $config.Run.PassThru             = $true
        $config.Output.Verbosity         = 'Normal'
        $config.CodeCoverage.Enabled     = $true
        $config.CodeCoverage.Path        = @(Get-ChildItem -LiteralPath (Join-Path $root '.github/orchestrator') -Recurse -File -Include '*.ps1', '*.psm1' |
            ForEach-Object { $_.FullName })
        $config.CodeCoverage.OutputPath  = $coverageFile
        $config.CodeCoverage.CoveragePercentTarget = 0   # gated below, on line coverage ($CoverageFloor)

        # A fresh record of what the tables and journeys do, read by the reports: the
        # label transitions, the exported functions reached, the journeys started.
        $global:OrchestratorJourneyTransitions = $null
        $global:OrchestratorExportReach = $null
        $global:OrchestratorJourneyStarts = 0
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
                $percent  = 100 * $hit.Count / $all.Count
                $coverage = 'line coverage {0:N1}% of .github/orchestrator/ ({1} of {2} lines)' -f $percent, $hit.Count, $all.Count
            }
        }
        $coverage += ", floor $CoverageFloor%"
        # The coverage gate.
        $covered = $percent -ge $CoverageFloor
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
    Write-Output ('Pester  {0}  {1:N1}s  Pester {2}  {3}' -f (& $verdict ($pesterPassed -and $covered)), $pesterTime, $pester.Version, $coverage)
} else {
    Write-Output 'Pester  not run — no tests/decisions/ or tests/journeys/ in this project'
}
if (-not $covered) {
    Write-Output "        line coverage is below the floor of $CoverageFloor% (`$CoverageFloor in .github/tasks/test.ps1)"
}
if ($pytestExit -ne 0 -or -not $pesterPassed -or -not $covered) { exit 1 }
exit 0
