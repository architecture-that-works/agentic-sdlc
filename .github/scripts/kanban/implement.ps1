#Requires -Version 7.0
<#
.SYNOPSIS
    Stage 2 — Implementing: Refine → Develop → PR.

.DESCRIPTION
    Phase A  Refine  — structures the issue body using the ISSUES.md template if
                       not already structured.
    Phase B  Develop — invokes Claude Code non-interactively to implement all
                       requirements and verify with uv run pytest.
    Phase C  PR      — commits (Claude-generated message), pushes, opens PR.

.PARAMETER Issue
    Issue number. Defaults to 0 — auto-detected from the current branch name.

.EXAMPLE
    task implement              # auto-detects issue from branch
    task implement ISSUE=13     # explicit issue number
#>
param([int]$Issue = 0)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

# ── Phase A: Refine ───────────────────────────────────────────────────────────

function Invoke-Refine {
    param([int]$Number)
    Write-Log "  Phase A — Refine issue #$Number" -Color Yellow

    $issue    = gh issue view $Number --json title,body | ConvertFrom-Json
    $template = Get-IssueTemplate

    if ($template) {
        $headings = ($template -split '\r?\n' | Where-Object { $_ -match '^\*\*\w' } |
            ForEach-Object { ($_ -split ':')[0] })
        $missing = $headings | Where-Object { $issue.body -notmatch [regex]::Escape($_) }
        if (-not $missing) {
            Write-Log "  Issue already structured — skipping refinement." -Color DarkGray
            return
        }
    }

    $templateInstruction = if ($template) {
        "Rewrite the issue body to match EXACTLY this field structure:`n`n$template`n`nFill each field with content derived from the raw issue. Do not invent requirements. Return only the filled body, no commentary."
    } else {
        "Structure the issue body with: **Goal**, **Description**, **Requirements** (numbered), **Acceptance Criteria** (bulleted). Return only the body."
    }

    $prompt = @"
You are structuring a GitHub issue body for this repository.

ISSUE TITLE: $($issue.title)
RAW BODY: $($issue.body)

$templateInstruction
"@

    $refined = claude -p $prompt 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Claude refinement failed: $refined" }

    $tmp = New-TemporaryFile
    try {
        $refined.Trim() | Out-File $tmp.FullName -Encoding utf8
        gh issue edit $Number --body-file $tmp.FullName 2>&1 | Out-Null
        Add-Comment -Number $Number -Body "📋 Issue refined using the project template. Starting implementation."
        Write-Log "  Issue #$Number refined." -Color Green
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

# ── Phase B: Develop ──────────────────────────────────────────────────────────

function Format-ToolLine {
    param([string]$Name, $Input)
    switch ($Name) {
        'Read'  { "📖 Read:  $($Input.file_path)" }
        'Write' { "✏️  Write: $($Input.file_path)" }
        'Edit'  { "✏️  Edit:  $($Input.file_path)" }
        'Glob'  { "🔍 Glob:  $($Input.pattern)" }
        'Grep'  { "🔍 Grep:  $($Input.pattern)" }
        'Bash'  { "⚡ Bash:  $([string]$Input.command -replace '\r?\n.*','' -replace '\s+',' ')" }
        default { "🔧 $Name" }
    }
}

function Invoke-Develop {
    param([int]$Number, [string]$Branch)
    Write-Log "  Phase B — Develop issue #$Number on $Branch" -Color Yellow
    Move-ToLane -IssueNumber $Number -OptionId $KanbanOpt_Implementing -LaneName 'Implementing'
    Add-Comment -Number $Number -Body "🌿 Branch ``$Branch`` checked out. Claude Code starting implementation..."

    $issue = gh issue view $Number --json title,body | ConvertFrom-Json

    $prompt = @"
You are implementing GitHub issue #$Number on branch $Branch in this repository.

ISSUE TITLE: $($issue.title)

ISSUE BODY:
$($issue.body)

INSTRUCTIONS:
1. Read AGENTS.md and CONTEXT.md first to understand the project boundaries and constraints.
2. Read the relevant parts of the codebase before writing any code.
3. Implement every requirement listed in the issue body completely.
4. Follow all conventions in AGENTS.md and the skills in .agents/skills/.
5. After implementation run ``uv run pytest`` to verify the test suite passes.
6. If tests fail, diagnose and fix the root cause before stopping.
7. Do NOT commit any changes — only implement.
8. End your response with a concise bullet-point summary of every file you changed.
"@

    $allText           = [System.Text.StringBuilder]::new()
    $modifiedFiles     = [System.Collections.Generic.List[string]]::new()
    $explorationPosted = $false
    $writingPosted     = $false
    $testedOnce        = $false

    claude -p $prompt --allowedTools "Read,Write,Edit,Bash,Glob,Grep" --output-format stream-json --verbose 2>&1 |
    ForEach-Object {
        $raw = [string]$_
        try {
            $ev = $raw | ConvertFrom-Json -ErrorAction Stop

            $blocks = if ($ev.message.content) { $ev.message.content }
                      elseif ($ev.content)      { $ev.content }
                      else                      { @() }

            foreach ($block in $blocks) {
                switch ($block.type) {
                    'text' {
                        Write-Host $block.text -NoNewline
                        $null = $allText.Append($block.text)
                    }
                    'tool_use' {
                        $inputReady = ($block.input.PSObject.Properties | Measure-Object).Count -gt 0
                        if ($inputReady) {
                            Write-Host "`n  $(Format-ToolLine -Name $block.name -Input $block.input)" -ForegroundColor DarkCyan
                        }

                        if ($block.name -in @('Read','Glob','Grep') -and -not $explorationPosted) {
                            $explorationPosted = $true
                            Add-Comment -Number $Number -Body "🔍 Exploring codebase..."
                        }
                        if ($block.name -in @('Write','Edit') -and $block.input.file_path) {
                            if (-not $writingPosted) {
                                $writingPosted = $true
                                Add-Comment -Number $Number -Body "🔨 Writing implementation..."
                            }
                            $fp = $block.input.file_path
                            if (-not $modifiedFiles.Contains($fp)) { $modifiedFiles.Add($fp) }
                        }
                        if ($block.name -eq 'Bash' -and $block.input.command -match 'pytest' -and -not $testedOnce) {
                            $testedOnce = $true
                            Add-Comment -Number $Number -Body "🧪 Running test suite..."
                        }
                    }
                }
            }

            if ($ev.type -eq 'result') { Write-Host '' }
        } catch {
            if ($raw.Trim()) { Write-Host $raw -ForegroundColor DarkGray }
        }
    }

    if ($LASTEXITCODE -ne 0) { throw "Claude Code exited with code $LASTEXITCODE." }

    $bullets     = ($allText.ToString() -split '\r?\n') |
                   Where-Object { $_ -match '^\s*[-*•]' } |
                   Select-Object -Last 20
    $summaryText = if ($bullets) { $bullets -join "`n" } else { '(see PR diff for details)' }
    $fileSection = if ($modifiedFiles.Count -gt 0) {
        $fileLines = ($modifiedFiles | Select-Object -Unique |
                      ForEach-Object { "- ``$(Split-Path $_ -Leaf)``" }) -join "`n"
        "`n`n**Files changed ($($modifiedFiles.Count)):**`n$fileLines"
    } else { '' }
    Add-Comment -Number $Number -Body "🤖 **Implementation complete**$fileSection`n`n$summaryText"
    Write-Log "  Implementation finished for issue #$Number." -Color Green

    # Independent verification
    Write-Log "  Running test suite independently..." -Color DarkGray
    $testOutput = uv run pytest 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Add-Comment -Number $Number -Body "⚠️ **Tests failing after implementation** — pipeline halted.`n``````text`n$testOutput`n``````"
        throw "Test suite failed after implementation for issue #$Number"
    }
    Add-Comment -Number $Number -Body "✅ **All tests passing** — moving to PR."
    Write-Log "  Tests passing ✅" -Color Green
}

# ── Phase C: Commit + PR ──────────────────────────────────────────────────────

function Invoke-CommitAndPR {
    param([int]$Number, [string]$Title, [string]$Branch)
    Write-Log "  Phase C — Commit + PR for issue #$Number" -Color Yellow

    git add . 2>&1 | Out-Null
    if (git status --porcelain) {
        $diff    = git diff --staged 2>&1 | Out-String
        $message = Get-CommitMessage -Diff $diff -FallbackMessage "feat(#${Number}): $Title"
        git commit -m $message 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git commit failed for issue #$Number" }
    } else {
        Write-Log "  ✅ Already implemented — no new changes on this branch." -Color Green
        Add-Comment -Number $Number -Body "✅ Issue already fully implemented on this branch — no new changes. Proceeding to PR and review."
    }

    git push --quiet origin HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { throw "git push failed for branch ${Branch}" }

    $existing = gh pr list --head $Branch --json url --limit 1 | ConvertFrom-Json
    if ($existing.Count -gt 0) {
        $prUrl = $existing[0].url
        Write-Log "  PR already exists: $prUrl" -Color DarkGray
    } else {
        $body = @"
## Summary
Automated implementation for issue #$Number by Claude Code agent.

## Validation
- ``uv run pytest`` — ✅ passed (verified by pipeline)

## Linked Issue
Closes #$Number
"@
        $tmp = New-TemporaryFile
        try {
            $body | Out-File $tmp.FullName -Encoding utf8
            $prUrl = gh pr create `
                --title "feat(#${Number}): $Title" `
                --body-file $tmp.FullName `
                --head $Branch 2>$null
            if ($LASTEXITCODE -ne 0) { throw "PR creation failed for issue #$Number" }
            $prUrl = $prUrl.Trim()
        } finally {
            Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
        }
        Write-Log "  PR created: $prUrl" -Color Green
    }

    Move-ToLane -IssueNumber $Number -OptionId $KanbanOpt_Review -LaneName 'Review'
    Add-Comment -Number $Number -Body "🔗 PR ready for review: $prUrl"
    return $prUrl
}

# ── Orchestrator ──────────────────────────────────────────────────────────────

function Invoke-Implement {
    param([int]$IssueNumber = 0, [switch]$Force)

    if ($IssueNumber -eq 0) { $IssueNumber = Get-CurrentIssueNumber }
    if ($IssueNumber -eq 0) {
        $queued = gh issue list --repo $KanbanRepo --state open --label 'agent:start' `
            --json number --limit 1 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($queued -and $queued.Count -gt 0) { $IssueNumber = $queued[0].number }
    }
    if ($IssueNumber -eq 0) {
        throw "No issue found. Pass ISSUE=N, run from a feature branch, or assign agent:start to an issue."
    }

    $meta           = gh issue view $IssueNumber --json title | ConvertFrom-Json
    $expectedBranch = Get-BranchName -Number $IssueNumber -Title $meta.title
    $branch         = git rev-parse --abbrev-ref HEAD

    if ($branch -ne $expectedBranch) {
        Write-Log "  Creating feature branch for issue #$IssueNumber..." -Color DarkGray
        Add-Comment -Number $IssueNumber -Body "🚀 Picked up via agent:start — creating branch ``$expectedBranch``."
        $branch = New-FeatureBranch -Number $IssueNumber -Title $meta.title
    }

    if (-not $Force) {
        $existingPR = gh pr list --head $branch --json number,url --limit 1 | ConvertFrom-Json
        if ($existingPR.Count -gt 0) {
            Write-Log "  PR #$($existingPR[0].number) already exists — skipping implement." -Color DarkGray
            return $existingPR[0].url
        }
    }

    Write-Log "▶ Implement — issue #$IssueNumber on $branch" -Color Cyan
    Ensure-AgentLabels

    $calledDirectly = $MyInvocation.InvocationName -ne '.'
    if ($calledDirectly) { Set-IssueLabel -Number $IssueNumber -Add 'agent:implementing' }

    try {
        Invoke-Refine      -Number $IssueNumber
        Invoke-Develop     -Number $IssueNumber -Branch $branch
        $prUrl = Invoke-CommitAndPR -Number $IssueNumber -Title $meta.title -Branch $branch

        if ($calledDirectly) { Set-IssueLabel -Number $IssueNumber -Remove 'agent:implementing' }
        Write-Log "✅ Implement complete — PR at $prUrl" -Color Green
        return $prUrl
    } catch {
        if ($calledDirectly) {
            Set-IssueLabel -Number $IssueNumber -Remove 'agent:implementing' -Add 'agent:failed'
        }
        Add-Comment -Number $IssueNumber -Body "❌ **Implement stage failed**`n``````$_``````"
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Implement -IssueNumber $Issue | Out-Null
}
