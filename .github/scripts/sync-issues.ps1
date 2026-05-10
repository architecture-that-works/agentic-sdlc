#Requires -Version 7.0
# .github/scripts/sync-issues.ps1
# Parses ISSUES.md ISSUE blocks → GitHub Issues + GitHub Project board.
#
# For each ISSUE: <title> ... END_ISSUE block below <!-- ISSUES -->:
#   1. Creates a GitHub Issue labelled repo:<repo-name> for multi-repo project filtering.
#   2. Adds the issue to the configured GitHub Project.
#   3. On success, removes the synced block from ISSUES.md.
#
# Idempotent: an existing open/closed issue with the same title is reused.

param(
    [switch]$DryRun,
    [int]$ProjectNumber = 0,
    [string]$ProjectOwner = ''
)

$ErrorActionPreference = 'Stop'

# ── Load .env ─────────────────────────────────────────────────────────────────

$_Root    = "$PSScriptRoot\..\.."
$_EnvPath = "$_Root\.env"

if (Test-Path $_EnvPath) {
    foreach ($line in (Get-Content $_EnvPath)) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$' -and $line -notmatch '^\s*#') {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim('"').Trim("'"), 'Process')
        }
    }
}

if ($ProjectNumber -eq 0) {
    $ProjectNumber = if ($env:KANBAN_PROJECT_NUMBER) { [int]$env:KANBAN_PROJECT_NUMBER } else { 0 }
}
if (-not $ProjectOwner) {
    $ProjectOwner = if ($env:KANBAN_PROJECT_OWNER) { $env:KANBAN_PROJECT_OWNER } else { '@me' }
}

# ── Resolve repo ──────────────────────────────────────────────────────────────

$IssuesPath = "$_Root\ISSUES.md"
if (-not (Test-Path $IssuesPath)) {
    Write-Error "ISSUES.md not found in the project root."
    exit 1
}

$Repo = gh repo view --json nameWithOwner --jq '.nameWithOwner'
if (-not $Repo) { Write-Error "Could not resolve current repo via gh."; exit 1 }
$RepoName  = ($Repo -split '/')[-1]
$RepoLabel = "repo:$RepoName"

# ── Resolve project name for display ─────────────────────────────────────────

$ProjectName = if ($ProjectNumber -gt 0) {
    gh project view $ProjectNumber --owner $ProjectOwner --format json --jq '.title' 2>$null
} else { $null }
if (-not $ProjectName) { $ProjectName = if ($ProjectNumber -gt 0) { "#$ProjectNumber" } else { '(no project configured)' } }

# ── Label registry — known labels with canonical colours ─────────────────────
# Add entries here for any label that sync-issues.ps1 should be able to create.
# Labels not listed here fall back to colour 'ededed' (light grey).

$script:LabelRegistry = @{
    'AFK'         = @{ Color = '0075ca'; Description = 'Agent executes start-to-finish without interruption' }
    'HITL'        = @{ Color = 'e4e669'; Description = 'Requires human decision or approval before closing' }
    'planning'    = @{ Color = 'c5def5'; Description = 'Planning artifact — PRD or Agent Brief' }
    'enhancement' = @{ Color = 'a2eeef'; Description = 'New feature or request' }
    'bug'         = @{ Color = 'd73a4a'; Description = 'Something is not working' }
}

# ── Ensure repo label ────────────────────────────────────────────────────────

function Ensure-Label([string]$Name, [string]$Color = 'ededed', [string]$Description = '') {
    # Prefer registry values when the caller passes no colour.
    if ($Color -eq 'ededed' -and $script:LabelRegistry.ContainsKey($Name)) {
        $Color       = $script:LabelRegistry[$Name].Color
        $Description = $script:LabelRegistry[$Name].Description
    }
    $existing = gh label list --repo $Repo --json name | ConvertFrom-Json | Where-Object { $_.name -eq $Name }
    if (-not $existing) {
        Write-Host "  Creating label '$Name'" -ForegroundColor Cyan
        if (-not $DryRun) {
            gh label create $Name --color $Color --description $Description --repo $Repo | Out-Null
        }
    }
}

Ensure-Label $RepoLabel '5319e7' "Belongs to $Repo"

# ── Parse ISSUES.md ───────────────────────────────────────────────────────────

$Content = Get-Content $IssuesPath -Raw

# Only parse content below the <!-- ISSUES --> sentinel
$SentinelIndex = $Content.IndexOf('<!-- ISSUES -->')
$ParseContent  = if ($SentinelIndex -ge 0) { $Content.Substring($SentinelIndex) } else { $Content }

$IssueRegex = '(?s)ISSUE:\s*(.*?)\r?\n(.*?)\r?\nEND_ISSUE'
$Found      = [regex]::Matches($ParseContent, $IssueRegex)

if ($Found.Count -eq 0) {
    Write-Host "✅ No pending ISSUE blocks found in ISSUES.md." -ForegroundColor Green
    exit 0
}

Write-Host "🚀 Found $($Found.Count) issue(s) to synchronize → project '$ProjectName'" -ForegroundColor Cyan

$Processed  = [System.Collections.Generic.List[string]]::new()
$NewContent = $Content

foreach ($match in $Found) {
    $FullBlock = $match.Value
    $Title     = $match.Groups[1].Value.Trim()
    $Body      = $match.Groups[2].Value.Trim()

    # Parse optional LABELS: line — must be the first line of the body.
    # Format:  LABELS: AFK, enhancement
    # Backward-compatible: issues without LABELS: work unchanged.
    $ExtraLabels = @()
    $BodyLines   = $Body -split '\r?\n'
    if ($BodyLines.Count -gt 0 -and $BodyLines[0] -match '^LABELS:\s*(.+)') {
        $ExtraLabels = ($Matches[1] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $Body        = ($BodyLines | Select-Object -Skip 1) -join "`n"
        $Body        = $Body.TrimStart()
        foreach ($lbl in $ExtraLabels) { Ensure-Label $lbl }
    }

    $Labels   = @($RepoLabel) + $ExtraLabels
    $LabelCsv = $Labels -join ','

    Write-Host ""
    Write-Host "  Processing: '$Title'  [labels: $LabelCsv]" -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would create issue and add to project '$ProjectName'" -ForegroundColor DarkGray
        continue
    }

    # Idempotent: reuse existing issue with same title
    $IssueUrl = $null
    $Existing = gh issue list --repo $Repo --state all --json number,title,url --limit 200 |
        ConvertFrom-Json |
        Where-Object { $_.title -eq $Title } |
        Select-Object -First 1

    if ($Existing) {
        $IssueUrl = $Existing.url
        Write-Host "  ♻️  Reusing existing issue: $IssueUrl" -ForegroundColor DarkYellow
    } else {
        $tmp = [System.IO.Path]::GetTempFileName()
        $Body | Out-File $tmp -Encoding utf8
        $result = gh issue create --repo $Repo --title $Title --label $LabelCsv --body-file $tmp 2>&1
        Remove-Item $tmp -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -eq 0) {
            $IssueUrl = ($result | Out-String).Trim()
            Write-Host "  ✅ Created: $IssueUrl" -ForegroundColor Green
        } else {
            Write-Host "  ❌ Failed to create issue '$Title': $result" -ForegroundColor Red
            continue
        }
    }

    # Add to project board
    if ($IssueUrl -and $ProjectNumber -gt 0) {
        $addResult = gh project item-add $ProjectNumber --owner $ProjectOwner --url $IssueUrl 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  📌 Added to project '$ProjectName'" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  Could not add to project (may already be present): $addResult" -ForegroundColor Yellow
        }
    }

    $Processed.Add($FullBlock)
}

# ── Burn down processed blocks ────────────────────────────────────────────────

if (-not $DryRun -and $Processed.Count -gt 0) {
    Write-Host ""
    Write-Host "♻️  Removing $($Processed.Count) synced block(s) from ISSUES.md..." -ForegroundColor Yellow
    foreach ($block in $Processed) {
        $escaped    = [regex]::Escape($block)
        $NewContent = [regex]::Replace($NewContent, "$escaped\s*", '')
    }
    $NewContent = $NewContent -replace '(\r?\n){3,}', "`r`n`r`n"
    $NewContent = [regex]::Replace($NewContent, '(?m)(^\s*---\s*\r?\n){2,}', "---`r`n")
    $NewContent.Trim() | Out-File $IssuesPath -Encoding utf8
    Write-Host "🎉 ISSUES.md updated." -ForegroundColor Cyan
}

if ($DryRun) {
    Write-Host ""
    Write-Host "✨ Dry run complete. No changes made." -ForegroundColor Cyan
}
