#Requires -Version 7.0
<#
    Settings.ps1 — the one reader of a repository's settings file (.env).

    Not a Command: a Library beside the Commands, dot-sourced at the top of every
    Command a person runs, before it imports the orchestrator. It holds one function,
    Import-Settings, which copies each `KEY=value` line of <Root>/.env into the process
    environment, where the orchestrator reads its board settings when it uses them.
    Importing the orchestrator module reads no file; a workflow passes the same
    settings as repository variables, and a test states them in the process
    environment.

    No top-level param() (ADR-013).
#>

# Reads <Root>/.env into the process environment: one `KEY=value` line per setting,
# `#` lines skipped, surrounding quotes dropped. A value in the file replaces the one
# the process has. -Root is the repository root (default: the one this file is in).
# A missing file is no error — the settings may come from the environment — unless
# -Required, which stops the run and names where the file should be.
function Import-Settings {
    param([string]$Root = '', [switch]$Required)
    if (-not $Root) { $Root = Join-Path $PSScriptRoot '../..' }
    $path = Join-Path $Root '.env'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($Required) { throw ".env not found at $([System.IO.Path]::GetFullPath($path)) — copy .env.example to .env and fill in KANBAN_PROJECT_NUMBER and KANBAN_PROJECT_OWNER." }
        return
    }
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim('"').Trim("'"), 'Process')
        }
    }
}
