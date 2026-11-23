#Requires -Version 7.0
# .github/tasks/sync.ps1
# Parses ISSUES.md ISSUE blocks → GitHub Issues + GitHub Project board.
#
# For each ISSUE: <title> ... END_ISSUE block below <!-- ISSUES -->:
#   1. Creates a GitHub Issue with any labels declared in the LABELS: header field.
#   2. Adds the issue to the configured GitHub Project.
#   3. On success, removes the synced block from ISSUES.md.
#
# Idempotent: an existing open/closed issue with the same title is reused.
#
# -Root is the repository root whose .env and ISSUES.md are read (default: the one
# this script is in).

param(
    [switch]$DryRun,
    [int]$ProjectNumber = 0,
    [string]$ProjectOwner = '',
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

# tasks/ is two levels below the repo root (.github/tasks/).
$_Root = if ($Root) { $Root } else { (Resolve-Path "$PSScriptRoot\..\..").ProviderPath }

# ── Load .env ─────────────────────────────────────────────────────────────────

. "$PSScriptRoot\Settings.ps1"
Import-Settings -Root $_Root

# The orchestrator module gives the issue template's headings (Get-IssueHeadings) and
# the repository slug, resolved without GraphQL (Get-OrchestratorContext, ADR-012).
if (-not (Get-Module Orchestrator)) { Import-Module "$PSScriptRoot\..\orchestrator\Orchestrator.psd1" }

if ($ProjectNumber -eq 0) {
    $ProjectNumber = if ($env:KANBAN_PROJECT_NUMBER) { [int]$env:KANBAN_PROJECT_NUMBER } else { 0 }
}
if (-not $ProjectOwner) {
    $ProjectOwner = if ($env:KANBAN_PROJECT_OWNER) { $env:KANBAN_PROJECT_OWNER } else { '@me' }
}

# ── Resolve repo ──────────────────────────────────────────────────────────────

$IssuesPath = Join-Path $_Root 'ISSUES.md'
if (-not (Test-Path $IssuesPath)) {
    Write-Error "ISSUES.md not found in the project root."
    exit 1
}

$Repo = (Get-OrchestratorContext).Repo
if (-not $Repo) { Write-Error "Could not resolve the repository — set GITHUB_REPOSITORY or add a git 'origin' remote."; exit 1 }

# Resolve project node ID once — needed for gh project item-edit field updates
$ProjectId = $null
if ($ProjectNumber -gt 0) {
    $ProjectId = gh project list --owner $ProjectOwner --format json --jq ".projects[] | select(.number == $ProjectNumber) | .id" 2>&1 |
                 Out-String | ForEach-Object { $_.Trim() }
}

# ── Resolve project name for display ─────────────────────────────────────────

$ProjectName = if ($ProjectNumber -gt 0) {
    gh project view $ProjectNumber --owner $ProjectOwner --format json --jq '.title' 2>$null
} else { $null }
if (-not $ProjectName) { $ProjectName = if ($ProjectNumber -gt 0) { "#$ProjectNumber" } else { '(no project configured)' } }

# Base labels (AFK, HITL, planning, enhancement, bug, agent:*) are provisioned once
# by setup.ps1 § "Provision base labels". Sync assumes a configured repo and applies
# labels declared in LABELS: headers without re-creating them per issue.

# ── Parse ISSUES.md ───────────────────────────────────────────────────────────

$Content = Get-Content $IssuesPath -Raw

# Only parse content below the <!-- ISSUES --> sentinel. Match it on its OWN LINE
# so a prose/backtick mention of the marker in the header docs above (e.g.
# "promote an item to a block below the `<!-- ISSUES -->` sentinel") is never
# mistaken for the real divider — IndexOf would otherwise split on that mention
# and parse the documentation as an ISSUE block.
$SentinelMatch = [regex]::Match($Content, '(?m)^<!-- ISSUES -->\s*$')
$ParseContent  = if ($SentinelMatch.Success) { $Content.Substring($SentinelMatch.Index) } else { $Content }

$IssueRegex = '(?s)```\r?\nISSUE:\s*(.*?)\r?\n(.*?)\r?\nEND_ISSUE\r?\n```'
$Found      = [regex]::Matches($ParseContent, $IssueRegex)

$RawTitleMatches = [regex]::Matches($ParseContent, '(?m)^ISSUE:\s*(.+)')
$FencedTitles    = @($Found | ForEach-Object { $_.Groups[1].Value.Trim() })
$UnfencedTitles  = @($RawTitleMatches | ForEach-Object { $_.Groups[1].Value.Trim() } |
                     Where-Object { $_ -notin $FencedTitles })
if ($UnfencedTitles.Count -gt 0) {
    Write-Host "❌ Unparsed ISSUE block(s) — missing fence or malformed:" -ForegroundColor Red
    foreach ($t in $UnfencedTitles) { Write-Host "   • $t" -ForegroundColor Red }
    exit 1
}

if ($Found.Count -eq 0) {
    Write-Host "✅ No pending ISSUE blocks found in ISSUES.md." -ForegroundColor Green
    exit 0
}

# Every block body carries every heading of the issue template (#369). Refuse the
# whole run — dry run included — before any issue is created.
$Headings   = @(@(Get-IssueHeadings -Root $_Root).Name)
$MissingAny = [System.Collections.Generic.List[string]]::new()
foreach ($match in $Found) {
    $blockTitle = $match.Groups[1].Value.Trim()
    $blockBody  = $match.Groups[2].Value
    $blockBody  = $blockBody -replace '(?m)^LABELS:\s*.+(\r?\n|$)', ''
    $blockBody  = $blockBody -replace '(?m)^ESTIMATE:\s*\d+(\r?\n|$)', ''
    $blockBody  = $blockBody -replace '(?m)^PRIORITY:\s*P[0-4](\r?\n|$)', ''
    foreach ($h in $Headings) {
        if ($blockBody -notmatch [regex]::Escape("**$h**")) { $MissingAny.Add("'$blockTitle' lacks **$h**") }
    }
}
if ($MissingAny.Count -gt 0) {
    Write-Host "❌ ISSUE block(s) missing a heading of .github/ISSUE_TEMPLATE/issue.md — nothing was synced:" -ForegroundColor Red
    foreach ($m in $MissingAny) { Write-Host "   • $m" -ForegroundColor Red }
    exit 1
}

Write-Host "🚀 Found $($Found.Count) issue(s) to synchronize → project '$ProjectName'" -ForegroundColor Cyan

$Processed  = [System.Collections.Generic.List[string]]::new()
$NewContent = $Content

foreach ($match in $Found) {
    $FullBlock = $match.Value
    $Title     = $match.Groups[1].Value.Trim()
    $Body      = $match.Groups[2].Value.Trim()

    # Parse optional header fields — LABELS, ESTIMATE, PRIORITY — before the body.
    # Fields may appear in any order; parsing stops at the first non-header line.
    # Backward-compatible: blocks without any header fields work unchanged.
    $ExtraLabels = @()
    $Estimate    = $null
    $Priority    = $null
    foreach ($line in ($Body -split '\r?\n')) {
        if     ($line -match '^LABELS:\s*(.+)')       { $ExtraLabels = ($Matches[1] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
        elseif ($line -match '^ESTIMATE:\s*(\d+)')    { $Estimate = [int]$Matches[1] }
        elseif ($line -match '^PRIORITY:\s*(P[0-4])') { $Priority = $Matches[1] }
        else   { break }
    }
    $Body = $Body -replace '(?m)^LABELS:\s*.+(\r?\n|$)', ''
    $Body = $Body -replace '(?m)^ESTIMATE:\s*\d+(\r?\n|$)', ''
    $Body = $Body -replace '(?m)^PRIORITY:\s*P[0-4](\r?\n|$)', ''
    $Body = $Body.TrimStart()

    # Labels are the pipeline's output: refine sets agent:* and human:decision when the
    # issue is opened (afk.yml), so sync never applies them. Only human:approval — the
    # owner forcing a merge hold — passes through.
    $pipelineLabels = @($ExtraLabels | Where-Object { $_ -like 'agent:*' -or $_ -eq 'human:decision' })
    if ($pipelineLabels.Count -gt 0) {
        Write-Host "  ⚠️  Ignoring label(s) [$($pipelineLabels -join ', ')] — refine sets these." -ForegroundColor Yellow
    }
    $Labels   = @($ExtraLabels | Where-Object { $_ -notlike 'agent:*' -and $_ -ne 'human:decision' })
    $LabelCsv = $Labels -join ','

    Write-Host ""
    Write-Host "  Processing: '$Title'  [labels: $(if ($LabelCsv) { $LabelCsv } else { '(none)' })]" -ForegroundColor Yellow

    if ($DryRun) {
        $dryFields = @(if ($LabelCsv) { "labels: $LabelCsv" } else { 'labels: (none)' })
        if ($null -ne $Estimate) { $dryFields += "estimate: $Estimate" }
        if ($Priority)           { $dryFields += "priority: $Priority" }
        Write-Host "  [DRY RUN] Would create issue and add to project '$ProjectName' [$($dryFields -join ', ')]" -ForegroundColor DarkGray
        continue
    }

    # Idempotent: reuse existing issue with same title
    $IssueUrl    = $null
    $IssueNumber = 0
    $Existing    = gh issue list --repo $Repo --state all --json number,title,url --limit 200 |
        ConvertFrom-Json |
        Where-Object { $_.title -eq $Title } |
        Select-Object -First 1

    if ($Existing) {
        $IssueUrl    = $Existing.url
        $IssueNumber = $Existing.number
        Write-Host "  ♻️  Reusing existing issue: $IssueUrl" -ForegroundColor DarkYellow
    } else {
        $tmp = [System.IO.Path]::GetTempFileName()
        $Body | Out-File $tmp -Encoding utf8
        $createArgs = @('issue', 'create', '--repo', $Repo, '--title', $Title, '--body-file', $tmp)
        if ($LabelCsv) { $createArgs += @('--label', $LabelCsv) }
        $result = gh @createArgs 2>&1
        Remove-Item $tmp -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -eq 0) {
            $IssueUrl    = ($result | Out-String).Trim()
            $IssueNumber = [int](($IssueUrl -split '/')[-1])
            Write-Host "  ✅ Created: $IssueUrl" -ForegroundColor Green
        } else {
            Write-Host "  ❌ Failed to create issue '$Title': $result" -ForegroundColor Red
            continue
        }
    }

    # Add to project board, capture item ID, then set Estimate and Priority fields
    if ($IssueUrl -and $ProjectNumber -gt 0) {
        $addJson = gh project item-add $ProjectNumber --owner $ProjectOwner --url $IssueUrl --format json 2>&1 | Out-String
        $itemId  = $null
        if ($LASTEXITCODE -eq 0) {
            try { $itemId = ($addJson.Trim() | ConvertFrom-Json).id } catch {}
            Write-Host "  📌 Added to project '$ProjectName'" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  Could not add to project (may already be present)" -ForegroundColor Yellow
        }

        # Fallback: resolve item ID via item-list when add returned non-zero (item already in project)
        if ((-not $itemId) -and ($null -ne $Estimate -or $Priority) -and $IssueNumber -gt 0) {
            $jq     = ".items[] | select(.content.number == $IssueNumber and .content.repository == `"$Repo`") | .id"
            $itemId = gh project item-list $ProjectNumber --owner $ProjectOwner --format json --limit 200 --jq $jq 2>&1 |
                      Out-String | ForEach-Object { $_.Trim() }
        }

        if ($itemId -and $ProjectId) {
            if ($null -ne $Estimate) {
                $fid = $env:KANBAN_ESTIMATE_FIELD_ID
                if ($fid) {
                    gh project item-edit --id $itemId --project-id $ProjectId --field-id $fid --number $Estimate 2>&1 | Out-Null
                    Write-Host "  📊 Estimate → $Estimate" -ForegroundColor DarkGray
                } else {
                    Write-Host "  ⚠️  KANBAN_ESTIMATE_FIELD_ID not set — skipping. Run: task setup" -ForegroundColor Yellow
                }
            }
            if ($Priority) {
                $fid   = $env:KANBAN_PRIORITY_FIELD_ID
                $optId = switch ($Priority) {
                    'P0' { $env:KANBAN_PRIORITY_OPT_P0 }
                    'P1' { $env:KANBAN_PRIORITY_OPT_P1 }
                    'P2' { $env:KANBAN_PRIORITY_OPT_P2 }
                    'P3' { $env:KANBAN_PRIORITY_OPT_P3 }
                    'P4' { $env:KANBAN_PRIORITY_OPT_P4 }
                }
                if ($fid -and $optId) {
                    gh project item-edit --id $itemId --project-id $ProjectId --field-id $fid --single-select-option-id $optId 2>&1 | Out-Null
                    Write-Host "  🎯 Priority → $Priority" -ForegroundColor DarkGray
                } else {
                    Write-Host "  ⚠️  KANBAN_PRIORITY_FIELD_ID or option not set — skipping. Run: task setup" -ForegroundColor Yellow
                }
            }
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
