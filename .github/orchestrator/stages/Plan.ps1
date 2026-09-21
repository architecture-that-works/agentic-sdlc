#Requires -Version 7.0
<#
.SYNOPSIS
    Backlog gate, Plan decomposition -- Lean PRD synthesis + child issues (epics).

.DESCRIPTION
    Kanban library -- loaded by Kanban.psm1. This is the heavy Plan path: when the
    Plan step (Refine.ps1 -> Invoke-Plan) sees an EPIC (estimate >= DecomposeThreshold)
    it hands off to Invoke-PlanDecomposition here, which synthesises a Lean PRD and
    fans the epic out into child issues. Ordinary issues keep the lightweight
    implementation-plan section written by Invoke-Plan.

    Plan is the third readiness stage (refine -> architect -> plan) -- NOT a kanban
    lane. Per ADR-011/ADR-014 the GitHub issue is the cross-runtime carrier:
      * Blast-radius is read FROM the issue's ARCH-IMPACT body section (written by
        Architecture.ps1) -- there is no .planning/ directory.
      * The Lean PRD is published as a BODY SECTION of the parent issue (between
        AGENT-PRD markers) -- not as a free-floating comment.

    Pipeline for one parent epic issue:
      1. Dedupe -- query open issues + grep `.out-of-scope.md` against the parent
         issue's key terms. Abort with a `🤖❌ Plan Aborted -- duplicate` signal
         comment (and WITHOUT granting readiness.planned) if overlap is found.
      2. PRD synthesis -- Claude produces a Lean PRD with the plan/SKILL.md six-
         section structure (Problem Statement, User Stories, Tracer Bullet,
         Implementation Decisions, Testing Decisions, Out of Scope) plus a
         children[] array sized >= 3.
      3. PRD published into the parent issue body section (AGENT-PRD markers); a
         signal comment announces it for downstream agents and humans.
      4. Child-issue emission -- sync-issues.ps1 block format (LABELS:/ESTIMATE:/
         PRIORITY: header + Goal/Description/Requirements/Acceptance Criteria).
         children[0] is the tracer bullet; children land via `gh issue create`.
      5. Heuristic:
           * wide blast OR open_questions[] non-empty -> human:decision
         Children may opt UP to human:decision via the synthesised PRD; never down.
#>

$ErrorActionPreference = 'Stop'
# Module-internal library -- loaded by Kanban.psm1 (which loads Config.ps1 and
# GitHub.ps1 first, so $KanbanStopWords, $KanbanRepo, $_Root, the AGENT-PRD /
# ARCH-IMPACT markers and the issue-body helpers are all in module scope). Not
# dot-sourced individually; carries no top-level param() block (ADR-013).

# ── Key-term extraction ──────────────────────────────────────────────────────
# Title → top-K content tokens after stop-word filtering. Used to query
# `gh issue list` for duplicates and to grep `.out-of-scope.md` headings.

function Get-PlanKeyTerms {
    param([string]$Title, [int]$Top = 5)
    $words = ($Title -replace '[^a-zA-Z0-9\s\-]', ' ' -split '\s+') |
        Where-Object { $_ -and $KanbanStopWords -notcontains $_.ToLower() -and $_.Length -ge 3 } |
        ForEach-Object { $_.ToLower() }
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($w in $words) {
        if (-not $unique.Contains($w)) { $unique.Add($w) }
    }
    if ($unique.Count -gt $Top) { return @($unique[0..($Top - 1)]) }
    return @($unique)
}

# ── Out-of-scope overlap ─────────────────────────────────────────────────────
# Returns the `## ` headings in `.out-of-scope.md` whose text overlaps any
# key term — the plan-phase dedupe gate's machine source of truth.

function Find-OutOfScopeOverlap {
    param(
        [Parameter(Mandatory)][string]$OutOfScopePath,
        [Parameter(Mandatory)][string[]]$KeyTerms
    )
    if (-not (Test-Path $OutOfScopePath)) { return @() }
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content $OutOfScopePath)) {
        if ($line -match '^##\s+(.+)$') {
            $heading  = $Matches[1].Trim()
            $haystack = $heading.ToLower()
            foreach ($term in $KeyTerms) {
                if (-not $term) { continue }
                $needle = [regex]::Escape($term.ToLower())
                if ($haystack -match "\b$needle\b") {
                    $hits.Add($heading)
                    break
                }
            }
        }
    }
    return @($hits)
}

# ── Open-issue overlap ───────────────────────────────────────────────────────

function Find-OpenIssueOverlap {
    param(
        [Parameter(Mandatory)][string[]]$KeyTerms,
        [int]$ExcludeIssue = 0
    )
    if (-not $KeyTerms -or $KeyTerms.Count -eq 0) { return @() }
    # gh issue list --search uses GitHub code-search syntax — only the first
    # 3 terms drive the query so noisy long titles do not over-constrain it.
    $query = ($KeyTerms | Select-Object -First 3) -join ' '
    $listJson = gh issue list --repo $KanbanRepo --search $query --state open `
        --json number,title --limit 20 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return @() }
    try {
        $items = $listJson | ConvertFrom-Json -ErrorAction Stop
    } catch { return @() }
    return @(@($items) | Where-Object { $_.number -ne $ExcludeIssue })
}

# ── Blast radius (read from the issue's ARCH-IMPACT body section) ────────────
# ADR-014: the Architect step (Architecture.ps1) writes the blast-radius impact
# INTO the issue body between ARCH-IMPACT markers — not a free-standing comment
# and not a .planning/ file. Read that section back so the Plan heuristic uses
# the freshest analysis on the cross-runtime carrier.

function Get-IssueBlastRadius {
    param([int]$IssueNumber)
    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $body) { return '' }
    $pattern = [regex]::Escape($KanbanArchBeginMarker) + '(?<impact>.*?)' + [regex]::Escape($KanbanArchEndMarker)
    $match   = [regex]::Match($body, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($match.Success) { return $match.Groups['impact'].Value.Trim() }
    return ''
}

# Narrow blast → at-risk is empty OR recommendation is "proceed".
# Missing report → treat as narrow (no signal of widespread risk).

function Test-NarrowBlast {
    param([string]$BlastText)
    if (-not $BlastText) { return $true }
    if ($BlastText -match '\*\*At-risk:\*\*\s*none\b')           { return $true }
    if ($BlastText -match '\*\*Recommendation:\*\*\s*proceed\b') { return $true }
    return $false
}

# ── Labelling heuristic ──────────────────────────────────────────────────────
# No label when blast is narrow AND there are no unresolved open_questions.
# Either signal flips the issue to human:decision — correctness for recursive issue
# creation matters more than throughput.

function Get-PlanLabel {
    param(
        [Parameter(Mandatory)][bool]$NarrowBlast,
        [int]$OpenQuestionCount = 0
    )
    if ($NarrowBlast -and $OpenQuestionCount -eq 0) { return '' }
    return 'human:decision'
}

# ── Child-issue block format (matches sync-issues.ps1 ISSUE: ... END_ISSUE) ──
# Returns the body string for one child issue — header fields first, then the
# Goal / Description / Requirements / Acceptance Criteria body. The block is
# identical in shape to a hand-written ISSUES.md block so existing tooling
# (sync-issues.ps1, the refine phase parser) handles them unchanged.

function Format-ChildIssue {
    param(
        [string]$Label,
        [int]$Estimate = 0,
        [string]$Priority,
        [Parameter(Mandatory)][string]$Goal,
        [Parameter(Mandatory)][string]$Description,
        [string[]]$Requirements = @(),
        [string[]]$AcceptanceCriteria = @()
    )
    $sb = [System.Text.StringBuilder]::new()
    if ($Label) { $null = $sb.AppendLine("LABELS: $Label") }
    if ($Estimate -gt 0) { $null = $sb.AppendLine("ESTIMATE: $Estimate") }
    if ($Priority)       { $null = $sb.AppendLine("PRIORITY: $Priority") }
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("**Goal**: $Goal")
    $null = $sb.AppendLine("**Description**: $Description")
    $null = $sb.AppendLine("**Requirements**:")
    if ($Requirements -and $Requirements.Count -gt 0) {
        $i = 1
        foreach ($req in $Requirements) { $null = $sb.AppendLine("$i. $req"); $i++ }
    } else {
        $null = $sb.AppendLine('1. _(populated by plan synthesis)_')
    }
    $null = $sb.AppendLine("**Acceptance Criteria**:")
    if ($AcceptanceCriteria -and $AcceptanceCriteria.Count -gt 0) {
        foreach ($ac in $AcceptanceCriteria) { $null = $sb.AppendLine("- [ ] $ac") }
    } else {
        $null = $sb.AppendLine('- [ ] _(populated by plan synthesis)_')
    }
    return $sb.ToString().TrimEnd()
}

function New-ChildIssue {
    param(
        [Parameter(Mandatory)][int]$ParentNumber,
        [Parameter(Mandatory)][pscustomobject]$Child
    )
    $requirements = @()
    if ($Child.PSObject.Properties['requirements'] -and $Child.requirements) { $requirements = @($Child.requirements) }
    $acceptance = @()
    if ($Child.PSObject.Properties['acceptance_criteria'] -and $Child.acceptance_criteria) { $acceptance = @($Child.acceptance_criteria) }
    $estimate = 0
    if ($Child.PSObject.Properties['estimate'] -and $null -ne $Child.estimate) { try { $estimate = [int]$Child.estimate } catch { $estimate = 0 } }
    $priority = ''
    if ($Child.PSObject.Properties['priority'] -and $Child.priority) { $priority = "$($Child.priority)" }
    $body = Format-ChildIssue `
        -Label              $Child.label `
        -Estimate           $estimate `
        -Priority           $priority `
        -Goal               $Child.goal `
        -Description        "$($Child.description)`n`n**Parent**: #$ParentNumber" `
        -Requirements       $requirements `
        -AcceptanceCriteria $acceptance

    $tmp = New-TemporaryFile
    try {
        $body | Out-File $tmp.FullName -Encoding utf8
        $ghArgs = @('issue', 'create',
            '--repo',      $KanbanRepo,
            '--title',     $Child.title,
            '--body-file', $tmp.FullName)
        if ($Child.label) {
            $ghArgs += '--label'
            $ghArgs += $Child.label
        }
        $url = gh @ghArgs 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Could not create child issue '$($Child.title)': $($url.Trim())" -Color Yellow
            return $null
        }
        return $url.Trim()
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

# ── Lean PRD body section ───────────────────────────────────────────────────
# Renders the synthesised PRD into the parent issue body between AGENT-PRD
# markers ($KanbanPrdBeginMarker/$KanbanPrdEndMarker from GitHub.ps1).
# Idempotent — re-runs replace the previous block in place.

function Format-PRDSection {
    param([Parameter(Mandatory)][pscustomobject]$Prd)
    $stories = if ($Prd.PSObject.Properties['user_stories'] -and $Prd.user_stories) {
        ($Prd.user_stories | ForEach-Object { "- $_" }) -join "`n"
    } else { '- _(none stated)_' }
    $impl = if ($Prd.PSObject.Properties['implementation_decisions'] -and $Prd.implementation_decisions) {
        ($Prd.implementation_decisions | ForEach-Object { "- $_" }) -join "`n"
    } else { '- _(none stated)_' }
    $tests = if ($Prd.PSObject.Properties['testing_decisions'] -and $Prd.testing_decisions) {
        ($Prd.testing_decisions | ForEach-Object { "- $_" }) -join "`n"
    } else { '- _(none stated)_' }
    $oos = if ($Prd.PSObject.Properties['out_of_scope'] -and $Prd.out_of_scope) {
        ($Prd.out_of_scope | ForEach-Object { "- $_" }) -join "`n"
    } else { '- _(none stated)_' }
    $tracer = if ($Prd.PSObject.Properties['tracer_bullet'] -and $Prd.tracer_bullet) { $Prd.tracer_bullet } else { '_(not yet identified)_' }
    $problem = if ($Prd.PSObject.Properties['problem_statement'] -and $Prd.problem_statement) { $Prd.problem_statement } else { '_(not yet stated)_' }

    @"
$KanbanPrdBeginMarker
## Lean PRD

**Problem Statement**
$problem

**User Stories**
$stories

**Tracer Bullet**
$tracer

**Implementation Decisions**
$impl

**Testing Decisions**
$tests

**Out of Scope**
$oos
$KanbanPrdEndMarker
"@
}

function Set-PRDSection {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][pscustomobject]$Prd
    )
    # Format-PRDSection already embeds the AGENT-PRD markers (the announce comment
    # reuses the same rendered block), so upsert it directly rather than through
    # Set-IssueBodySection — that helper would wrap a SECOND marker pair around it.
    $section = Format-PRDSection -Prd $Prd
    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not read issue body for #${IssueNumber} — skipping PRD section write." -Color Yellow
        return
    }
    $body = $body.TrimEnd("`r", "`n")
    $pattern = [regex]::Escape($KanbanPrdBeginMarker) + '.*?' + [regex]::Escape($KanbanPrdEndMarker)
    $opts    = [System.Text.RegularExpressions.RegexOptions]::Singleline
    if ([regex]::IsMatch($body, $pattern, $opts)) {
        # Callback-based Replace sidesteps $1/$& substitution in the replacement string.
        $newBody = [regex]::Replace($body, $pattern, { param($m) $section }, $opts)
    } else {
        $newBody = "$body`n`n$section"
    }
    $tmp = New-TemporaryFile
    try {
        $newBody | Out-File $tmp.FullName -Encoding utf8
        $out = gh issue edit $IssueNumber --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to write Lean PRD on #${IssueNumber}: $($out.Trim())" -Color Yellow
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

# ── PRD synthesis (Claude) ──────────────────────────────────────────────────

function Invoke-PrdSynthesis {
    param([int]$IssueNumber)
    $issue = gh issue view $IssueNumber --repo $KanbanRepo --json title,body | ConvertFrom-Json

    $prompt = @"
You are synthesising a Lean PRD from a refined GitHub Issue per the plan/SKILL.md schema.

ISSUE TITLE: $($issue.title)
ISSUE BODY:
$($issue.body)

Return ONLY valid JSON — no fences, no prose — matching this shape:
{
  "problem_statement": "<one paragraph from user's perspective; final sentence states the success criterion>",
  "user_stories": ["<As a ..., I want ..., so that ...>", "<...>", "<...>"],
  "tracer_bullet": "<single narrowest vertical slice that proves the pipe end-to-end>",
  "implementation_decisions": ["<schema/contract only — no file paths>"],
  "testing_decisions": ["<unit/integration/acceptance per touched module>"],
  "out_of_scope": ["<X — deferred because Y>"],
  "children": [
    {
      "title": "<short, action-oriented child issue title>",
      "label": "<leave empty, or 'human:decision'>",
      "estimate": 2,
      "priority": "P3",
      "goal": "<one-sentence goal>",
      "description": "<what, why, context — no implementation steps>",
      "requirements": ["<r1>", "<r2>"],
      "acceptance_criteria": ["<a1>", "<a2>"]
    }
  ]
}

Rules:
- children[0] MUST be the tracer bullet (narrowest vertical slice).
- >= 3 children in total.
- Assign the 'human:decision' label if the child genuinely needs a human decision
  (UX, credentials, business call). Otherwise leave the label empty.
  The orchestrator may upgrade to human:decision based on the blast-radius heuristic;
  it never downgrades.
- Estimates use Fibonacci 1/2/3/5/8/13. Use 13 only when the child needs
  decomposition itself — prefer breaking it further.
- Priorities are P0..P4. Use P3 unless the child is explicitly higher.
"@

    $raw = if ($KanbanEngine -eq 'gemini') {
        Remove-GeminiNoise -Text ($prompt | agy --model $KanbanModel_GeminiFlash 2>&1 | Out-String)
    } else {
        Remove-ClaudeNoise -Text ($prompt | claude --model $KanbanModel_Sonnet 2>&1 | Out-String)
    }
    if ($LASTEXITCODE -ne 0) { throw "Claude PRD synthesis failed: $raw" }
    $json = $raw.Trim()
    if ($json -match '(?s)```(?:json)?\s*(\{.+\})\s*```') { $json = $Matches[1] }
    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

# ── Epic decomposition entry point ───────────────────────────────────────────
# Called by Invoke-Plan (Refine.ps1) when the issue is an epic. Returns the
# number of child issues created, or $null when it aborts (duplicate / zero
# children). On abort it deliberately does NOT set readiness.planned, so the
# alignment gate stays closed for a duplicate epic.

function Invoke-PlanDecomposition {
    param([int]$IssueNumber)
    Write-Log "  Plan — decomposing epic #$IssueNumber into child issues" -Color Yellow

    $issue = gh issue view $IssueNumber --repo $KanbanRepo --json title,body | ConvertFrom-Json

    # ── 1. Dedupe ───────────────────────────────────────────────────────────
    $keyTerms = Get-PlanKeyTerms -Title $issue.title -Top 5
    Write-Log "  Key terms: $($keyTerms -join ', ')" -Color DarkGray

    $oosPath     = "$_Root\.out-of-scope.md"
    $oosOverlap  = Find-OutOfScopeOverlap -OutOfScopePath $oosPath -KeyTerms $keyTerms
    $openOverlap = Find-OpenIssueOverlap  -KeyTerms       $keyTerms -ExcludeIssue $IssueNumber

    if (@($oosOverlap).Count -gt 0 -or @($openOverlap).Count -gt 0) {
        $msg = [System.Text.StringBuilder]::new()
        $null = $msg.AppendLine('🤖❌ Plan Aborted — duplicate')
        $null = $msg.AppendLine()
        if (@($oosOverlap).Count -gt 0) {
            $null = $msg.AppendLine('**Out-of-scope overlap:**')
            foreach ($h in $oosOverlap) { $null = $msg.AppendLine("- $h") }
        }
        if (@($openOverlap).Count -gt 0) {
            if (@($oosOverlap).Count -gt 0) { $null = $msg.AppendLine() }
            $null = $msg.AppendLine('**Open-issue overlap:**')
            foreach ($i in $openOverlap) { $null = $msg.AppendLine("- #$($i.number) $($i.title)") }
        }
        Add-Comment -Number $IssueNumber -Body $msg.ToString().TrimEnd()
        Write-Log "  Plan aborted — duplicate detected for issue #$IssueNumber" -Color Red
        return $null
    }

    # ── 2. PRD synthesis ────────────────────────────────────────────────────
    $prd = Invoke-PrdSynthesis -IssueNumber $IssueNumber

    # ── 3. Publish PRD to body section + announce via signal comment ────────
    Set-PRDSection -IssueNumber $IssueNumber -Prd $prd
    $announce = Format-PRDSection -Prd $prd
    Add-Comment -Number $IssueNumber -Body "🤖 Plan — Lean PRD published`n`n$announce"
    Write-Log "  Lean PRD written into #$IssueNumber body and announced via signal comment" -Color Green

    # ── 4. Labelling heuristic ──────────────────────────────────────────────
    $blastText = Get-IssueBlastRadius -IssueNumber $IssueNumber
    $narrow    = Test-NarrowBlast -BlastText $blastText
    $state     = Get-IssueState -IssueNumber $IssueNumber
    $openCount = if ($state -and $state.open_questions) { @($state.open_questions).Count } else { 0 }
    $defaultLabel = Get-PlanLabel -NarrowBlast $narrow -OpenQuestionCount $openCount
    Write-Log "  Heuristic: narrowBlast=$narrow openQuestions=$openCount → default label = $defaultLabel" -Color DarkGray

    # ── 5. Child-issue emission ─────────────────────────────────────────────
    $children = if ($prd.PSObject.Properties['children']) { @($prd.children) } else { @() }
    if ($children.Count -eq 0) {
        Write-Log "  ⚠️ PRD synthesis returned zero children — nothing to emit." -Color Yellow
        Add-Comment -Number $IssueNumber -Body '🤖⚠️ Plan — PRD synthesis returned zero children; decomposition skipped.'
        return $null
    }

    $createdUrls = [System.Collections.Generic.List[string]]::new()
    $childIdx    = 0
    foreach ($c in $children) {
        $childIdx++
        # Children may opt UP to human:decision (Claude flagged it as such); the heuristic
        # may opt the orchestrator's default UP to human:decision — never down.
        $modelLabel = if ($c.PSObject.Properties['label'] -and $c.label) { "$($c.label)" } else { '' }
        $effective  = if ($modelLabel -eq 'human:decision' -or $defaultLabel -eq 'human:decision') { 'human:decision' } else { '' }
        $c | Add-Member -NotePropertyName label -NotePropertyValue $effective -Force

        $url = New-ChildIssue -ParentNumber $IssueNumber -Child $c
        if ($url) { $createdUrls.Add("Child #${childIdx} (${effective}): $url") }
    }

    if ($createdUrls.Count -gt 0) {
        $summary = "🤖 Plan — decomposition complete`n`n" +
                   "**Children emitted**: $($createdUrls.Count)`n" +
                   ($createdUrls -join "`n")
        Add-Comment -Number $IssueNumber -Body $summary
    }

    Set-PlanningReadiness -IssueNumber $IssueNumber -Stage 'planned' -StageLabel 'plan' -PopulatedBy 'plan-decomposition'
    Write-Log "  Plan decomposition complete for #$IssueNumber — $($createdUrls.Count) child(ren) created." -Color Green
    return $createdUrls.Count
}
