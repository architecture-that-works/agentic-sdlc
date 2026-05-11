#Requires -Version 7.0
<#
.SYNOPSIS
    Start the self-hosted GitHub Actions runner in this terminal.

.DESCRIPTION
    Checks if the runner is already active, then starts run.cmd.
    Press Ctrl+C to stop.
#>

$RunnerCmd = 'C:\Users\Yanni\Github\actions-runner\run.cmd'

if (-not (Test-Path $RunnerCmd)) {
    Write-Host "Runner not found at $RunnerCmd" -ForegroundColor Red
    Write-Host "Re-run the runner setup at: github.com/<repo>/settings/actions/runners/new" -ForegroundColor Yellow
    exit 1
}

$proc = Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host "Runner already active (PID $($proc.Id)) — nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host "GitHub Actions runner starting — Ctrl+C to stop." -ForegroundColor Cyan
& cmd /c $RunnerCmd
