#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap — discover GitHub Project field/option IDs and write to .env + GitHub Actions variables.

.DESCRIPTION
    Reads KANBAN_PROJECT_NUMBER and KANBAN_PROJECT_OWNER from .env, queries the
    GitHub Project for the Status field and all its option IDs, then:
      1. Writes the discovered IDs back to .env for local use (task run/implement/etc.)
      2. Sets matching GitHub Actions repository variables for kanban-lanes.yml

    Run once after creating the GitHub Project and setting KANBAN_PROJECT_NUMBER
    and KANBAN_PROJECT_OWNER in .env.

.EXAMPLE
    task setup
#>

$ErrorActionPreference = 'Stop'

$_Root    = "$PSScriptRoot\..\..\.."
$_EnvPath = "$_Root\.env"

# ── Load .env ─────────────────────────────────────────────────────────────────

if (-not (Test-Path $_EnvPath)) {
    Write-Error ".env not found at $_EnvPath"
    exit 1
}

foreach ($line in (Get-Content $_EnvPath)) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$' -and $line -notmatch '^\s*#') {
        [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim('"').Trim("'"), 'Process')
    }
}

$ProjectNumber = if ($env:KANBAN_PROJECT_NUMBER) { [int]$env:KANBAN_PROJECT_NUMBER } else { 0 }
$ProjectOwner  = if ($env:KANBAN_PROJECT_OWNER)  { $env:KANBAN_PROJECT_OWNER }       else { '' }

if ($ProjectNumber -eq 0) {
    Write-Error "KANBAN_PROJECT_NUMBER is not set in .env. Add it and re-run task setup."
    exit 1
}
if (-not $ProjectOwner) {
    Write-Error "KANBAN_PROJECT_OWNER is not set in .env. Add it and re-run task setup."
    exit 1
}

Write-Host ""
Write-Host "🔍 Querying project #$ProjectNumber (owner: $ProjectOwner)..." -ForegroundColor Cyan

# ── Fetch field list ──────────────────────────────────────────────────────────

$fieldsJson = gh project field-list $ProjectNumber --owner $ProjectOwner --format json 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to list project fields: $fieldsJson"
    exit 1
}

$fields      = ($fieldsJson | ConvertFrom-Json).fields
$statusField = $fields | Where-Object { $_.type -eq 'ProjectV2SingleSelectField' -and $_.name -match 'status|state' } | Select-Object -First 1

if (-not $statusField) {
    $statusField = $fields | Where-Object { $_.type -eq 'ProjectV2SingleSelectField' } | Select-Object -First 1
}
if (-not $statusField) {
    Write-Error "No SINGLE_SELECT field found in project #$ProjectNumber. Add a Status field to the project first."
    exit 1
}

Write-Host "  Found field: '$($statusField.name)' (ID: $($statusField.id))" -ForegroundColor Green
$options = $statusField.options

Write-Host ""
Write-Host "  Options:" -ForegroundColor Cyan
$options | ForEach-Object { Write-Host ("    [{0}] {1}" -f $_.id, $_.name) -ForegroundColor White }

$estimateField = $fields | Where-Object { $_.name -match '^estimate$' } | Select-Object -First 1
$priorityField = $fields | Where-Object { $_.type -eq 'ProjectV2SingleSelectField' -and $_.name -match '^priority$' } | Select-Object -First 1

if ($estimateField) {
    Write-Host "  Found field: '$($estimateField.name)' (ID: $($estimateField.id))" -ForegroundColor Green
} else {
    Write-Host "  ⚠️  No 'Estimate' field found — Estimate sync will be skipped." -ForegroundColor Yellow
}
if ($priorityField) {
    Write-Host "  Found field: '$($priorityField.name)' (ID: $($priorityField.id))" -ForegroundColor Green
    Write-Host "  Priority options:" -ForegroundColor Cyan
    $priorityField.options | ForEach-Object { Write-Host ("    [{0}] {1}" -f $_.id, $_.name) -ForegroundColor White }
} else {
    Write-Host "  ⚠️  No 'Priority' field found — Priority sync will be skipped." -ForegroundColor Yellow
}

# ── Auto-detect lane options ──────────────────────────────────────────────────

function Find-Option([string[]]$Patterns) {
    foreach ($p in $Patterns) {
        $match = $options | Where-Object { $_.name -match $p } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $null
}

$laneBacklog      = Find-Option @('backlog', 'todo', 'to.do', 'new')
$laneImplementing = Find-Option @('implement', 'progress', 'doing', 'in.progress')
$laneReview       = Find-Option @('review', 'testing', 'qa')
$laneMerged       = Find-Option @('merged?', 'done', 'complete', 'closed')

# ── Interactive fallback for unmatched lanes ──────────────────────────────────

function Select-Option([string]$LaneName, $Current) {
    if ($Current) {
        Write-Host "  Auto-detected '$LaneName' → '$($Current.name)'" -ForegroundColor DarkGray
        return $Current
    }
    Write-Host ""
    Write-Host "  Could not auto-detect '$LaneName'. Select the matching option:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-Host ("    {0}. {1}" -f ($i + 1), $options[$i].name) -ForegroundColor White
    }
    $raw = Read-Host "  Pick a number (1-$($options.Count))"
    $idx = [int]$raw - 1
    if ($idx -lt 0 -or $idx -ge $options.Count) { throw "Invalid selection for '$LaneName'." }
    return $options[$idx]
}

Write-Host ""
Write-Host "  Mapping lanes..." -ForegroundColor Cyan
$laneBacklog      = Select-Option 'Backlog'      $laneBacklog
$laneImplementing = Select-Option 'Implementing' $laneImplementing
$laneReview       = Select-Option 'Review'       $laneReview
$laneMerged       = Select-Option 'Merged'       $laneMerged

# ── Write .env ────────────────────────────────────────────────────────────────

function Set-EnvVar([string]$Path, [string]$Key, [string]$Value) {
    $lines  = if (Test-Path $Path) { Get-Content $Path } else { @() }
    $found  = $false
    $result = foreach ($line in $lines) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=") {
            "$Key=$Value"
            $found = $true
        } else {
            $line
        }
    }
    if (-not $found) { $result += "$Key=$Value" }
    $result | Out-File $Path -Encoding utf8
}

Write-Host ""
Write-Host "  Writing IDs to .env..." -ForegroundColor Cyan

Set-EnvVar $_EnvPath 'KANBAN_STATUS_FIELD_ID'  $statusField.id
Set-EnvVar $_EnvPath 'KANBAN_OPT_BACKLOG'      $laneBacklog.id
Set-EnvVar $_EnvPath 'KANBAN_OPT_IMPLEMENTING' $laneImplementing.id
Set-EnvVar $_EnvPath 'KANBAN_OPT_REVIEW'       $laneReview.id
Set-EnvVar $_EnvPath 'KANBAN_OPT_MERGED'       $laneMerged.id

if ($estimateField) { Set-EnvVar $_EnvPath 'KANBAN_ESTIMATE_FIELD_ID' $estimateField.id }
if ($priorityField) {
    Set-EnvVar $_EnvPath 'KANBAN_PRIORITY_FIELD_ID' $priorityField.id
    foreach ($opt in $priorityField.options) {
        Set-EnvVar $_EnvPath "KANBAN_PRIORITY_OPT_$($opt.name)" $opt.id
    }
}

# ── Set GitHub Actions repository variables ───────────────────────────────────

Write-Host "  Setting GitHub Actions repository variables..." -ForegroundColor Cyan

$ghVars = @{
    KANBAN_PROJECT_NUMBER   = "$ProjectNumber"
    KANBAN_PROJECT_OWNER    = $ProjectOwner
    KANBAN_STATUS_FIELD_ID  = $statusField.id
    KANBAN_OPT_BACKLOG      = $laneBacklog.id
    KANBAN_OPT_IMPLEMENTING = $laneImplementing.id
    KANBAN_OPT_REVIEW       = $laneReview.id
    KANBAN_OPT_MERGED       = $laneMerged.id
}
if ($estimateField) { $ghVars['KANBAN_ESTIMATE_FIELD_ID'] = $estimateField.id }
if ($priorityField) {
    $ghVars['KANBAN_PRIORITY_FIELD_ID'] = $priorityField.id
    foreach ($opt in $priorityField.options) { $ghVars["KANBAN_PRIORITY_OPT_$($opt.name)"] = $opt.id }
}

foreach ($kv in $ghVars.GetEnumerator()) {
    $out = gh variable set $kv.Key --body $kv.Value 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠️ Could not set GH variable '$($kv.Key)': $($out.Trim())" -ForegroundColor Yellow
    } else {
        Write-Host "  ✅ $($kv.Key) = $($kv.Value)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "✅ Setup complete. Run 'task run' to start the orchestrator." -ForegroundColor Green
