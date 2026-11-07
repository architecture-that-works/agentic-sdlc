#Requires -Version 7.0
<#
    GitHub.ps1 — every GitHub interaction for the Kanban module.

    Labels and agent:* state transitions, issue comments, feature branches, the
    Projects v2 board (items, lanes, fields), and the issue-body carriers: the
    AGENT-STATE planning JSON (ADR-011), the AGENT-BRIEF section, and
    HITL child issues. Label reads/writes use REST (issues/{n}/labels); board ops
    are GraphQL-only (no REST API) and cache the item list per process (ADR-012).
    Loaded after Config.ps1 + Util.ps1.
#>

# ── Label helpers ─────────────────────────────────────────────────────────────
# Base labels (agent:*, HITL, etc.) are provisioned once by setup.ps1. The
# pipeline assumes a configured project and never re-creates them per issue.

function Set-IssueLabel {
    param([int]$Number, [string]$Add = '', [string]$Remove = '')
    # Route label add/remove through REST (issues/{n}/labels), NOT `gh issue edit`
    # which is GraphQL. This runs on every state transition — the single most
    # frequent gh call in a drain — so moving it onto the near-idle REST budget is
    # the biggest GraphQL lever. A swap is two REST calls (DELETE then POST) rather
    # than one GraphQL edit; REST capacity is plentiful, so that trade is worth it.
    if ($Remove) {
        # URL-encode the label name — it is a path segment. agent:* labels work
        # unencoded, but a future label with a space or slash would not; gh api
        # passes the path through without re-encoding (%3A stays %3A).
        $removeEnc = [uri]::EscapeDataString($Remove)
        $out = gh api --method DELETE "repos/$KanbanRepo/issues/$Number/labels/$removeEnc" 2>&1 | Out-String
        # 404 just means the label was already absent — not worth surfacing.
        if ($LASTEXITCODE -ne 0 -and $out -notmatch 'HTTP 404|Not Found') {
            Write-Log "  ⚠️ Failed to remove label '$Remove' on #${Number}: $($out.Trim())" -Color Yellow
        }
    }
    if ($Add) {
        $out = gh api --method POST "repos/$KanbanRepo/issues/$Number/labels" -f "labels[]=$Add" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to add label '$Add' on #${Number}: $($out.Trim())" -Color Yellow
        }
    }
}

# ── Issue-carried planning state (cross-runtime carrier — ADR-011) ───────────
# State lives inside the issue body as a fenced JSON block between two HTML
# comment markers. Human-readable Markdown coexists outside the block and is
# never touched. Single source of truth across runtimes — no local files.

$KanbanStateBeginMarker = '<!-- AGENT-STATE:BEGIN -->'
$KanbanStateEndMarker   = '<!-- AGENT-STATE:END -->'

# AGENT-BRIEF is the self-grill subagent's structured Agent Brief, rendered as a
# Markdown section (same carrier as AGENT-STATE, different markers so each can be
# regex-replaced independently).
$KanbanBriefBeginMarker = '<!-- AGENT-BRIEF:BEGIN -->'
$KanbanBriefEndMarker   = '<!-- AGENT-BRIEF:END -->'

# ARCH-IMPACT and PLAN are the Backlog-gate alignment artefacts (Architect and
# Plan steps). Per ADR-014 the architectural blast-radius and the implementation
# plan live IN the issue body — there is no .planning/ directory. Each is a
# marker-bounded Markdown section so Set-IssueBodySection can upsert it without
# touching the prose, the Agent Brief, or the AGENT-STATE block.
$KanbanArchBeginMarker = '<!-- ARCH-IMPACT:BEGIN -->'
$KanbanArchEndMarker   = '<!-- ARCH-IMPACT:END -->'
$KanbanPlanBeginMarker = '<!-- PLAN:BEGIN -->'
$KanbanPlanEndMarker   = '<!-- PLAN:END -->'

# AGENT-PRD is the Lean PRD the Plan step publishes into an EPIC's body when it
# decomposes the epic into child issues (Plan.ps1). Same independent-marker
# pattern — regex-replaceable without touching the plan/arch/brief/state blocks.
$KanbanPrdBeginMarker = '<!-- AGENT-PRD:BEGIN -->'
$KanbanPrdEndMarker   = '<!-- AGENT-PRD:END -->'

# DECISIONS is the human-readable view of the open/decided questions in AGENT-STATE,
# re-rendered whenever they change, so the owner reads (and answers) them in the issue.
$KanbanDecisionsBeginMarker = '<!-- DECISIONS:BEGIN -->'
$KanbanDecisionsEndMarker   = '<!-- DECISIONS:END -->'

# ATTEMPTS is the failure history: every failed attempt (stage, what failed, when)
# and the current status, so the next attempt — agent or human — sees what was tried.
$KanbanAttemptsBeginMarker = '<!-- ATTEMPTS:BEGIN -->'
$KanbanAttemptsEndMarker   = '<!-- ATTEMPTS:END -->'

function Get-IssueState {
    param([int]$IssueNumber)

    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $body) { return $null }

    $pattern = [regex]::Escape($KanbanStateBeginMarker) +
               '\s*```json\s*\r?\n(?<json>.+?)\r?\n```\s*' +
               [regex]::Escape($KanbanStateEndMarker)
    $match = [regex]::Match($body, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        return [pscustomobject]@{
            issue_number       = $IssueNumber
            lane               = 'backlog'
            readiness          = [pscustomobject]@{
                refined     = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
                architected = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
                planned     = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
            }
            open_questions    = @()
            decided_questions = @()
            transitions       = @()
        }
    }

    try {
        return $match.Groups['json'].Value | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "  ⚠️ Could not parse AGENT-STATE block on #${IssueNumber}: $_" -Color Yellow
        return $null
    }
}

function Set-PlanningState {
    param([int]$IssueNumber, [pscustomobject]$State)

    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not read issue body for #${IssueNumber} — skipping state write." -Color Yellow
        return
    }
    $body = $body.TrimEnd("`r", "`n")

    $json  = $State | ConvertTo-Json -Depth 10
    $block = "$KanbanStateBeginMarker`n``````json`n$json`n```````n$KanbanStateEndMarker"

    $pattern = [regex]::Escape($KanbanStateBeginMarker) +
               '.*?' +
               [regex]::Escape($KanbanStateEndMarker)
    $opts    = [System.Text.RegularExpressions.RegexOptions]::Singleline
    if ([regex]::IsMatch($body, $pattern, $opts)) {
        # Callback-based Replace sidesteps $1/$& substitution in the replacement string.
        $newBody = [regex]::Replace($body, $pattern, { param($m) $block }, $opts)
    } else {
        $newBody = "$body`n`n$block"
    }

    $tmp = New-TemporaryFile
    try {
        $newBody | Out-File $tmp.FullName -Encoding utf8
        $out = gh issue edit $IssueNumber --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to write planning state on #${IssueNumber}: $($out.Trim())" -Color Yellow
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

function Test-Readiness {
    param([pscustomobject]$State)
    if ($null -eq $State) { return $false }
    if ($null -eq $State.readiness) { return $false }
    $refined     = [bool]$State.readiness.refined.done
    $architected = [bool]$State.readiness.architected.done
    $planned     = [bool]$State.readiness.planned.done
    $openCount   = if ($null -ne $State.open_questions) { @($State.open_questions).Count } else { 0 }
    return ($refined -and $architected -and $planned -and $openCount -eq 0)
}

# Marks a pre-backlog stage (refine|architect|plan) complete in the issue-carried
# state. Used by Invoke-Refine and the architect/plan stubs.
function Set-PlanningReadiness {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][ValidateSet('refined','architected','planned')][string]$Stage,
        [string]$StageLabel,
        [string]$PopulatedBy
    )
    if (-not $StageLabel) {
        $StageLabel = switch ($Stage) {
            'refined'     { 'refine' }
            'architected' { 'architect' }
            'planned'     { 'plan' }
        }
    }
    # `(phase-1 stub)` remains the default provenance for the architect/plan stubs
    # that have not yet been replaced. The self-grill subagent (issue #85) passes
    # -PopulatedBy 'self-grill-subagent' so audit trails distinguish the real
    # alignment phase from the stub copies.
    if (-not $PopulatedBy) {
        $PopulatedBy = "$StageLabel (phase-1 stub)"
    }

    $state = Get-IssueState -IssueNumber $IssueNumber
    if ($null -eq $state) {
        Write-Log "  ⚠️ Could not load planning state for #${IssueNumber} — skipping readiness update." -Color Yellow
        return
    }

    $ts = (Get-Date).ToUniversalTime().ToString('o')

    if ($null -eq $state.readiness) {
        $state | Add-Member -NotePropertyName readiness -NotePropertyValue ([pscustomobject]@{
            refined     = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
            architected = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
            planned     = [pscustomobject]@{ done = $false; populated_by = $null; timestamp = $null }
        }) -Force
    }
    $flag = [pscustomobject]@{
        done         = $true
        populated_by = $PopulatedBy
        timestamp    = $ts
    }
    $state.readiness | Add-Member -NotePropertyName $Stage -NotePropertyValue $flag -Force

    if ($null -eq $state.issue_number) {
        $state | Add-Member -NotePropertyName issue_number -NotePropertyValue $IssueNumber -Force
    }
    if ($null -eq $state.lane) {
        $state | Add-Member -NotePropertyName lane -NotePropertyValue 'backlog' -Force
    }
    if ($null -eq $state.open_questions) {
        $state | Add-Member -NotePropertyName open_questions -NotePropertyValue @() -Force
    }
    if ($null -eq $state.decided_questions) {
        $state | Add-Member -NotePropertyName decided_questions -NotePropertyValue @() -Force
    }
    if ($null -eq $state.transitions) {
        $state | Add-Member -NotePropertyName transitions -NotePropertyValue @() -Force
    }
    # Seed an initial transitions[] entry so the audit log is never empty after
    # the first stage completes — Phase 3 schedulers parse this on resume.
    if (@($state.transitions).Count -eq 0) {
        $state.transitions = @([pscustomobject]@{
            from      = $null
            to        = [string]$state.lane
            runtime   = (Get-RuntimeName)
            timestamp = $ts
        })
    }

    Set-PlanningState -IssueNumber $IssueNumber -State $state
}

# Merges the self-grill subagent's open_questions[] and decided_questions[] into
# the issue-carried planning state. Open questions are REPLACED on each refine run
# (the latest grill is authoritative); decided questions are APPENDED.
function Set-PlanningQuestions {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [pscustomobject[]]$Open    = @(),
        [pscustomobject[]]$Decided = @()
    )

    $state = Get-IssueState -IssueNumber $IssueNumber
    if ($null -eq $state) {
        Write-Log "  ⚠️ Could not load planning state for #${IssueNumber} — skipping question merge." -Color Yellow
        return
    }

    if ($null -eq $state.open_questions)    { $state | Add-Member -NotePropertyName open_questions    -NotePropertyValue @() -Force }
    if ($null -eq $state.decided_questions) { $state | Add-Member -NotePropertyName decided_questions -NotePropertyValue @() -Force }

    $state.open_questions    = @($Open)
    $state.decided_questions = @(@($state.decided_questions) + @($Decided))

    Set-PlanningState -IssueNumber $IssueNumber -State $state
}

# ── Agent Brief writer (self-grill subagent output → issue body) ─────────────
function Set-AgentBrief {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][pscustomobject]$Brief,
        [string]$PopulatedBy = 'self-grill-subagent'
    )

    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not read issue body for #${IssueNumber} — skipping Agent Brief write." -Color Yellow
        return
    }
    $body = $body.TrimEnd("`r", "`n")

    $ts = (Get-Date).ToUniversalTime().ToString('o')

    $interfaces  = if ($Brief.interfaces)  { ($Brief.interfaces  | ForEach-Object { "- $_" }) -join "`n" } else { '- _(none stated)_' }
    $constraints = if ($Brief.constraints) { ($Brief.constraints | ForEach-Object { "- $_" }) -join "`n" } else { '- _(none stated)_' }
    $outOfScope  = if ($Brief.out_of_scope){ ($Brief.out_of_scope| ForEach-Object { "- $_" }) -join "`n" } else { '- _(none stated)_' }
    $tracer      = if ($Brief.tracer_bullet) { $Brief.tracer_bullet } else { '_(not yet identified)_' }

    $section = @"
$KanbanBriefBeginMarker
## Agent Brief

``````yaml
feature_name: $($Brief.feature_name)
populated_by: $PopulatedBy
timestamp:    $ts
``````

**Problem Statement**
$($Brief.problem_statement)

**Interfaces**
$interfaces

**Constraints**
$constraints

**Out of Scope**
$outOfScope

**Tracer Bullet**
$tracer
$KanbanBriefEndMarker
"@

    $pattern = [regex]::Escape($KanbanBriefBeginMarker) + '.*?' + [regex]::Escape($KanbanBriefEndMarker)
    $opts    = [System.Text.RegularExpressions.RegexOptions]::Singleline
    if ([regex]::IsMatch($body, $pattern, $opts)) {
        $newBody = [regex]::Replace($body, $pattern, { param($m) $section }, $opts)
    } else {
        $newBody = "$body`n`n$section"
    }

    $tmp = New-TemporaryFile
    try {
        $newBody | Out-File $tmp.FullName -Encoding utf8
        $out = gh issue edit $IssueNumber --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to write Agent Brief on #${IssueNumber}: $($out.Trim())" -Color Yellow
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

# Upserts a marker-bounded Markdown section into the issue body (ADR-014). The
# section is delimited by HTML-comment markers so it can be regex-replaced
# without disturbing the prose, the Agent Brief, or the AGENT-STATE JSON block.
# Used by the Backlog-gate Architect (ARCH-IMPACT) and Plan (PLAN) steps so their
# artefacts live in the issue — the single cross-runtime carrier, no .planning/.
function Set-IssueBodySection {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$BeginMarker,
        [Parameter(Mandatory)][string]$EndMarker,
        [Parameter(Mandatory)][string]$Markdown
    )

    $body = gh issue view $IssueNumber --repo $KanbanRepo --json body --jq '.body' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not read issue body for #${IssueNumber} — skipping body-section write." -Color Yellow
        return $false
    }
    $body    = $body.TrimEnd("`r", "`n")
    $section = "$BeginMarker`n$Markdown`n$EndMarker"

    $pattern = [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker)
    $opts    = [System.Text.RegularExpressions.RegexOptions]::Singleline
    if ([regex]::IsMatch($body, $pattern, $opts)) {
        $newBody = [regex]::Replace($body, $pattern, { param($m) $section }, $opts)
    } else {
        $newBody = "$body`n`n$section"
    }

    $tmp = New-TemporaryFile
    try {
        $newBody | Out-File $tmp.FullName -Encoding utf8
        $out = gh issue edit $IssueNumber --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to write body section on #${IssueNumber}: $($out.Trim())" -Color Yellow
            return $false
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
    return $true
}

# ── Decisions in the issue (the carrier) ─────────────────────────────────────
# Open questions are asked IN the issue they block: a "## Decisions" body section
# rendered from the AGENT-STATE block, plus a 🤖⏸ comment. The owner answers with a
# plain comment; Invoke-AnswerCheck (Refine.ps1) reads it back.
# Open questions as multiple choice: A is the recommendation, B and C the
# alternatives, "Other" the owner's own words. Shared by the body section and the
# 🤖⏸ comment so both read the same.
function Format-DecisionQuestions {
    param([object[]]$Questions)
    $n = 1
    $blocks = foreach ($q in @($Questions | Where-Object { $_ })) {
        $lines = @("**$n. $($q.text)**")
        if ($q.decision) { $lines += "- **A — recommended:** $($q.decision)" }
        $letter = [int][char]'B'
        foreach ($alt in @($q.alternatives | Where-Object { $_ })) {
            $lines += "- **$([char]$letter):** $alt"
            $letter++
        }
        $lines += '- **Other:** your own answer'
        if ($q.PSObject.Properties['follow_up'] -and $q.follow_up) { $lines += "- _Still needed:_ $($q.follow_up)" }
        $n++
        $lines -join "`n"
    }
    return ($blocks -join "`n`n")
}

$KanbanReplyGuide = @'
**How to reply** — a plain comment on this issue; no @-mention or keyword needed:
- `ok` — accept every recommendation (A)
- `1B` or `2C` — pick an option per question
- `2: <your own words>` — your own answer
- mix them: `ok, but 2B` · `1A, 2: only for src/`

Your reply is checked automatically: answered questions are recorded under **Decisions** in the issue, anything unclear comes back as a follow-up, and implementation starts on its own once nothing is open.
'@

function Set-DecisionSection {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)]$State)

    $open    = @($State.open_questions    | Where-Object { $_ })
    $decided = @($State.decided_questions | Where-Object { $_ })
    if ($open.Count -eq 0 -and $decided.Count -eq 0) { return }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('## Decisions')
    if ($open.Count -gt 0) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('### Waiting on you')
        $null = $sb.AppendLine()
        $null = $sb.AppendLine((Format-DecisionQuestions -Questions $open))
        $null = $sb.AppendLine()
        $null = $sb.AppendLine($KanbanReplyGuide)
    }
    if ($decided.Count -gt 0) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('### Decided')
        $null = $sb.AppendLine()
        foreach ($q in $decided) {
            $by = if ($q.decided_by) { " _($($q.decided_by))_" } else { '' }
            $null = $sb.AppendLine("- $($q.text) → $($q.decision)$by")
        }
    }
    $null = Set-IssueBodySection -IssueNumber $IssueNumber `
        -BeginMarker $KanbanDecisionsBeginMarker -EndMarker $KanbanDecisionsEndMarker `
        -Markdown $sb.ToString().TrimEnd()
}

# Comments written by a person with write access — the owner's answers and
# guidance. Excluded: pipeline comments (it posts as the owner's PAT, so it is
# recognised by the 🤖 / · prefix Add-Comment enforces) and anyone without write
# access, whose text must never reach an agent prompt. -Since limits to comments
# created or edited after that moment; it takes a string or a [datetime], because
# ConvertFrom-Json turns the carrier's ISO timestamps into [datetime], which
# interpolates as "09/23/2026 23:05:54" — a format the API rejects (HTTP 422).
# -Strict throws on a failed read instead of returning nothing, for callers that
# must not mistake "could not read" for "no comments".
function Get-OwnerComments {
    param([Parameter(Mandatory)][int]$IssueNumber, [object]$Since = $null, [switch]$Strict)

    $path = "repos/$KanbanRepo/issues/$IssueNumber/comments?per_page=100"
    if ($Since) {
        $at = if ($Since -is [datetime]) { $Since.ToUniversalTime() }
              else { [datetimeoffset]::Parse("$Since", [cultureinfo]::InvariantCulture).UtcDateTime }
        $path += "&since=$($at.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture))"
    }
    # One JSON object per line (@json), across every page — an issue that went
    # through the pipeline carries many noise comments, so the newest owner comment
    # can sit beyond the first page.
    $jq = '.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")' +
          ' | select((.body | startswith("🤖") or startswith("·")) | not)' +
          ' | {login: .user.login, created_at: .created_at, body: .body} | @json'
    $out = gh api --paginate $path --jq $jq 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msg = "Could not read comments on #${IssueNumber}: $(($out | Out-String).Trim())"
        if ($Strict) { throw $msg }
        Write-Log "  ⚠️ $msg" -Color Yellow
        return @()
    }
    return @($out | Where-Object { "$_".Trim() } | ForEach-Object {
        try { "$_" | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ })
}

# The owner's comments as a prompt block ('' when there are none). Every stage
# that writes or judges the work reads it, so context or guidance written in a
# comment reaches the agent without editing the issue body.
function Format-OwnerComments {
    param([Parameter(Mandatory)][int]$IssueNumber)
    $comments = @(Get-OwnerComments -IssueNumber $IssueNumber)
    if ($comments.Count -eq 0) { return '' }
    $lines = $comments | ForEach-Object { "[$($_.login), $($_.created_at)]`n$($_.body)" }
    return "`nOWNER COMMENTS (oldest first — the issue owner's decisions, context and instructions; " +
           "they take precedence over earlier agent output):`n" + ($lines -join "`n---`n") + "`n"
}

# ── Attempts (failure history in the carrier) ────────────────────────────────
# A stage failure does not fail the issue at once: the conductor retries up to
# MaxRetries attempts per round. Each failed attempt is appended to attempts[] in
# AGENT-STATE (full history, kept across rounds) and attempt_count (this round),
# and rendered as the "## Attempts" body section, which the next attempt reads.
function Add-FailedAttempt {
    param(
        [Parameter(Mandatory)][int]$IssueNumber,
        [Parameter(Mandatory)][string]$Stage,
        [string]$Reason,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][int]$Max
    )
    $state = Get-IssueState -IssueNumber $IssueNumber
    if ($null -eq $state) { return }
    $short = ("$Reason" -replace '\s+', ' ').Trim()
    if ($short.Length -gt 400) { $short = $short.Substring(0, 397) + '...' }
    $history = @($state.attempts | Where-Object { $_ }) + [pscustomobject]@{
        attempt   = $Attempt
        of        = $Max
        stage     = $Stage
        reason    = $short
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }
    $state | Add-Member -NotePropertyName attempts      -NotePropertyValue @($history) -Force
    $state | Add-Member -NotePropertyName attempt_count -NotePropertyValue $Attempt    -Force
    Set-PlanningState -IssueNumber $IssueNumber -State $state
    Set-AttemptsSection -IssueNumber $IssueNumber -State $state -Max $Max
}

# Starts a new round: after success, or when the owner asks for a retry.
function Reset-AttemptCount {
    param([Parameter(Mandatory)][int]$IssueNumber)
    $state = Get-IssueState -IssueNumber $IssueNumber
    if ($null -eq $state -or -not $state.PSObject.Properties['attempt_count'] -or -not $state.attempt_count) { return }
    $state | Add-Member -NotePropertyName attempt_count -NotePropertyValue 0 -Force
    Set-PlanningState -IssueNumber $IssueNumber -State $state
    Set-AttemptsSection -IssueNumber $IssueNumber -State $state
}

function Set-AttemptsSection {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)]$State, [int]$Max = 0)
    $history = @($State.attempts | Where-Object { $_ })
    if ($history.Count -eq 0) { return }
    $count  = if ($State.PSObject.Properties['attempt_count']) { [int]$State.attempt_count } else { 0 }
    $status = if ($count -eq 0)                    { 'no failure in the current round' }
              elseif ($Max -gt 0 -and $count -ge $Max) { "failed $count/$Max — waiting on you: fix it hands-on or comment with guidance, then comment to retry" }
              elseif ($Max -gt 0)                  { "retrying — $count/$Max attempts used" }
              else                                 { "$count failed attempt(s) this round" }

    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('## Attempts')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("**Status:** $status")
    $null = $sb.AppendLine()
    foreach ($a in $history) {
        $null = $sb.AppendLine("- **Attempt $($a.attempt)/$($a.of)** · $($a.stage) · $($a.timestamp) — $($a.reason)")
    }
    $null = Set-IssueBodySection -IssueNumber $IssueNumber `
        -BeginMarker $KanbanAttemptsBeginMarker -EndMarker $KanbanAttemptsEndMarker `
        -Markdown $sb.ToString().TrimEnd()
}

# ── Usage-limit pause and resume ──────────────────────────────────────────────
# A spent usage allowance parks the issue on agent:paused with the resume time and
# the stage to resume in the carrier; no attempt is counted. afk.yml's hourly
# resume job calls Resume-PausedIssues.
function Suspend-ForUsageLimit {
    param([Parameter(Mandatory)][int]$IssueNumber, [Parameter(Mandatory)][string]$Stage,
          [Parameter(Mandatory)][datetime]$Until)
    $state = Get-IssueState -IssueNumber $IssueNumber
    if ($state) {
        $state | Add-Member -NotePropertyName paused_until -NotePropertyValue $Until.ToUniversalTime().ToString('o') -Force
        $state | Add-Member -NotePropertyName paused_stage -NotePropertyValue $Stage -Force
        Set-PlanningState -IssueNumber $IssueNumber -State $state
    }
    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:paused'
    Add-Comment -Number $IssueNumber -Body ("🤖⏳ Paused — the Claude usage limit is reached. $Stage resumes automatically " +
        "after $($Until.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC (checked hourly). No attempt was counted; nothing for you to do.")
    Write-Log "⏳ Issue #$IssueNumber paused at $Stage until $($Until.ToString('o'))." -Color Yellow
}

# Resumes every agent:paused issue whose resume time has passed — after one probe
# confirms the engine answers again; if it still refuses, the resume times move to
# the new reset time without a comment. Implement-stage pauses go back to
# agent:backlog (the label restarts implement); refine-stage pauses are dispatched
# to the refine job.
function Resume-PausedIssues {
    $raw = gh issue list --repo $KanbanRepo --label 'agent:paused' --state open --json number --jq '.[].number' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to list agent:paused issues: $raw" }
    $numbers = @($raw | Where-Object { "$_".Trim() } | ForEach-Object { [int]"$_" })
    if ($numbers.Count -eq 0) { Write-Log "No paused issues." -Color DarkGray; return }

    $now = (Get-Date).ToUniversalTime()
    $due = foreach ($n in $numbers) {
        $st = Get-IssueState -IssueNumber $n
        $until = if ($st -and $st.PSObject.Properties['paused_until'] -and $st.paused_until) {
            ([datetime]$st.paused_until).ToUniversalTime()
        } else { $now }
        if ($until -le $now) { [pscustomobject]@{ Number = $n; State = $st } }
    }
    $due = @($due | Where-Object { $_ })
    if ($due.Count -eq 0) { Write-Log "$($numbers.Count) paused issue(s); none due yet." -Color DarkGray; return }

    $still = Test-EngineUsageLimit
    if ($still) {
        foreach ($d in $due) {
            if ($d.State) {
                $d.State | Add-Member -NotePropertyName paused_until -NotePropertyValue $still.ToString('o') -Force
                Set-PlanningState -IssueNumber $d.Number -State $d.State
            }
        }
        Write-Log "⏳ Usage limit still in effect — $($due.Count) issue(s) now resume after $($still.ToString('o'))." -Color Yellow
        return
    }

    foreach ($d in $due) {
        $stage = if ($d.State -and $d.State.PSObject.Properties['paused_stage']) { "$($d.State.paused_stage)" } else { 'implement' }
        if ($d.State) {
            $d.State.PSObject.Properties.Remove('paused_until')
            $d.State.PSObject.Properties.Remove('paused_stage')
            Set-PlanningState -IssueNumber $d.Number -State $d.State
        }
        Add-Comment -Number $d.Number -Body "· resumed after the usage-limit pause ($stage)"
        if ($stage -eq 'refine') {
            Set-IssueLabel -Number $d.Number -Remove 'agent:paused'
            gh workflow run afk.yml --repo $KanbanRepo --field stage=refine --field issue_number=$($d.Number) 2>&1 | Out-Null
        } else {
            Set-AgentState -IssueNumber $d.Number -Label 'agent:backlog'
        }
        Write-Log "▶ Issue #$($d.Number) resumed ($stage)." -Color Green
    }
}

# ── Atomic state transition (label + lane in one call) ───────────────────────

function Set-AgentFailedState {
    param([int]$IssueNumber, [string]$FailedAt, [string]$Reason)
    
    $state = Get-IssueState -IssueNumber $IssueNumber
    if ($state) {
        if ($null -eq $state.failed_at) {
            $state | Add-Member -NotePropertyName failed_at -NotePropertyValue $FailedAt -Force
        } else {
            $state.failed_at = $FailedAt
        }
        if ($null -eq $state.failed_reason) {
            $state | Add-Member -NotePropertyName failed_reason -NotePropertyValue $Reason -Force
        } else {
            $state.failed_reason = $Reason
        }
        Set-PlanningState -IssueNumber $IssueNumber -State $state
    }
    
    Set-AgentState -IssueNumber $IssueNumber -Label 'agent:failed'
}

# The one setter for every pipeline label: the agent:* states and the two human:*
# holds. An issue carries exactly one of them (#225) — setting one replaces whichever
# the issue has, other labels are untouched, and the board lane follows. An owner's
# human:approval is a merge-hold request: when a later state replaces the label, the
# request moves into the carrier (approval_required) so ship still holds the PR.
function Set-AgentState {
    param([int]$IssueNumber, [string]$Label)

    # The lane comes from $PipelineStates (lib/Config.ps1) — the one table that says
    # what each pipeline label means. This used to be two parallel switch statements
    # over the same label set, i.e. two copies of one mapping that could disagree.
    #
    # The board option id is resolved here, not stored in the table: $KanbanOpt_* are
    # repository variables, and freezing them into the table at load time made every
    # lane move a no-op whenever they were set after the module loaded.
    $spec     = $PipelineStates[$Label]
    $laneName = if ($spec) { $spec.LaneName } else { '' }
    $laneId   = if ($laneName) { Get-LaneOptionId -LaneName $laneName } else { '' }

    # Readiness gate: backlog entry requires refined + architected + planned and zero open questions.
    if ($Label -eq 'agent:backlog') {
        $state = Get-IssueState -IssueNumber $IssueNumber
        if (-not (Test-Readiness -State $state)) {
            Write-Log "  ⚠️ Readiness gate FAILED for #${IssueNumber} — refusing entry to Backlog. Run refine/architect/plan first." -Color Yellow
            return
        }
    }

    # Read the labels via REST (Get-IssueLabel), not the GraphQL `gh issue view`.
    # Hot path — runs on every transition. "Which labels are the pipeline's" is the
    # key set of $PipelineStates, so a new state is recognised here by adding its row.
    $current = @(Get-IssueLabel -IssueNumber $IssueNumber |
        Where-Object { $PipelineStates.Contains($_) })
    $replace = @($current | Where-Object { $_ -ne $Label })

    if ($replace -contains 'human:approval' -and $Label -ne 'agent:shipped') {
        $state = Get-IssueState -IssueNumber $IssueNumber
        if ($state) {
            $state | Add-Member -NotePropertyName approval_required -NotePropertyValue $true -Force
            Set-PlanningState -IssueNumber $IssueNumber -State $state
        }
    }
    foreach ($old in $replace) { Set-IssueLabel -Number $IssueNumber -Remove $old }
    if ($current -notcontains $Label) { Set-IssueLabel -Number $IssueNumber -Add $Label }

    if ($laneId -and $laneName) {
        Move-ToLane -IssueNumber $IssueNumber -OptionId $laneId -LaneName $laneName
    }
}

function Get-IssueLabel {
    <#
    .SYNOPSIS
        All label names on an issue, read via REST.
    .DESCRIPTION
        The orchestrator is GraphQL-bound (ADR-012), and reading labels through
        `gh issue view` costs GraphQL points. Every label read goes through this
        one REST call so tests/orchestrator/test_graphql_budget.py has a single
        place to hold the line.
    #>
    param([int]$IssueNumber)

    $out = gh api "repos/$KanbanRepo/issues/$IssueNumber/labels" --jq 'map(.name) | .[]' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not read labels on #${IssueNumber}: $($out.Trim())" -Color Yellow
        return @()
    }
    return @($out.Trim() -split '
?
' | Where-Object { $_ })
}

# The single definition of "this issue's own merge/close event was already
# processed" (#275). agent:shipped is the only terminal label for this question —
# agent:failed is NOT: a human fixing a failed issue by hand and merging is exactly
# the case that must still transition to agent:shipped (#266). Exported so both the
# cheap pre-check in afk.yml's pr-closed job and Complete-HeldPR's own guard call the
# same rule instead of each re-typing it — afk.yml's bash check re-typing this exact
# rule, and drifting from it, is what left #268 stuck at agent:failed after #267.
function Test-IssueShipped {
    param([int]$IssueNumber)
    return (@(Get-IssueLabel -IssueNumber $IssueNumber) -contains 'agent:shipped')
}

# ── Comment helper ────────────────────────────────────────────────────────────

function Add-Comment {
    param([int]$Number, [string]$Body)
    # Every pipeline comment starts with 🤖 (signal) or · (noise). The pipeline posts
    # with the owner's PAT, so this prefix is the only thing that tells its comments
    # apart from the owner's — afk.yml ignores prefixed comments, and a missing prefix
    # would make the pipeline react to its own output.
    $lead = $Body.TrimStart()
    if (-not ($lead.StartsWith('🤖') -or $lead.StartsWith('·'))) { $Body = "· $Body" }
    $tmp = New-TemporaryFile
    try {
        $Body | Out-File $tmp.FullName -Encoding utf8
        $out = gh issue comment $Number --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ⚠️ Failed to post comment on #${Number}: $($out.Trim())" -Color Yellow
        }
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

# ── Branch helpers ────────────────────────────────────────────────────────────

function Get-BranchName {
    param([int]$Number, [string]$Title)
    $words = ($Title -replace '[^a-zA-Z0-9\s]', '' -split '\s+') |
        Where-Object { $_ -and $KanbanStopWords -notcontains $_.ToLower() } |
        Select-Object -First 3 |
        ForEach-Object { $_.ToLower() }
    "feature/$Number-$($words -join '-')"
}

function Get-CurrentIssueNumber {
    $branch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($branch -match 'feature/(\d+)') { return [int]$Matches[1] }
    return 0
}

# True when origin already carries this branch. Used to distinguish "first run for
# this issue" from "resuming work that was already pushed" — a distinction an
# ephemeral CI runner cannot make from local refs alone, because it clones only the
# default branch and therefore never has a local feature branch.
function Test-RemoteBranch {
    param([string]$Branch)
    # Deliberately NOT `--exit-code`: that flag makes git exit 2 when the ref is absent,
    # leaving $LASTEXITCODE poisoned for whatever the caller does next. This module
    # tests $LASTEXITCODE after native commands throughout, so a predicate must not
    # disturb it. Without the flag ls-remote exits 0 either way and empty output is the
    # signal.
    $out = git ls-remote --heads origin $Branch 2>$null | Out-String
    return (-not [string]::IsNullOrWhiteSpace($out))
}

function New-FeatureBranch {
    param([int]$Number, [string]$Title)
    $branch  = Get-BranchName -Number $Number -Title $Title
    $default = $KanbanDefaultBranch
    $current = git rev-parse --abbrev-ref HEAD

    if (git branch --list $branch) {
        if ($current -ne $branch) { git checkout --quiet $branch }
    } elseif (Test-RemoteBranch -Branch $branch) {
        # Remote carries prior work for this issue but this clone has no local branch.
        # That is the NORMAL state on a hosted runner, which checks out only the
        # default branch. Falling through to the creation path below would cut a new
        # branch from the default, orphaning the pushed commits and guaranteeing a
        # non-fast-forward rejection at push time. Observed on issue #154: the agent
        # re-implemented the work, the suite passed (251 tests), then the push was
        # refused and everything died with the runner.
        #
        # Fetch with an explicit refspec so refs/remotes/origin/<branch> definitely
        # exists — --force-with-lease on the later push needs that remote-tracking ref.
        git fetch --quiet origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not fetch existing remote branch $branch" }
        git checkout --quiet -B $branch "origin/$branch"
        if ($LASTEXITCODE -ne 0) { throw "Could not check out existing branch $branch from origin" }
        Write-Log "  Resumed branch $branch from origin (prior work preserved)." -Color DarkGray
    } else {
        if ($current -ne $default) {
            git checkout --quiet $default
            if ($LASTEXITCODE -ne 0) { throw "Could not switch to $default before creating feature branch" }
        }
        git fetch --quiet origin $default 2>$null
        git reset --hard --quiet "origin/$default" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not sync $default with origin" }

        gh issue develop $Number --name $branch --base $default --checkout 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  gh issue develop failed — falling back to git checkout -b" -Color Yellow
            git checkout --quiet -b $branch
        }
        Write-Log "  Created branch $branch (linked to issue #$Number)" -Color DarkGray
    }

    $dirty = git status --porcelain 2>$null
    if ($dirty) {
        git stash push --include-untracked -m "auto-stash before retry of issue #$Number" 2>&1 | Out-Null
        Write-Log "  Stashed leftover changes on $branch before retry." -Color DarkGray
    }

    $assignee = if ($env:GITHUB_ACTOR) { $env:GITHUB_ACTOR } else { '@me' }
    gh issue edit $Number --repo $KanbanRepo --add-assignee $assignee 2>&1 | Out-Null
    Write-Log "  Branch $branch — ready." -Color DarkGray
    return $branch
}

# ── Project board helpers ─────────────────────────────────────────────────────

$script:_CachedProjectId  = $null
$script:_CachedItems      = $null
$script:_ProjectIdFailed  = $false
$script:_ItemsFailed      = $false
$script:_ResolvedOwner    = $null
$script:_AuthDiagPrinted  = $false

# Trusts the configured owner. Setup resolves and validates it once; runtime
# probing masked the real gh error from callers. Downstream gh project calls
# surface their actual error message instead of a generic "cannot resolve owner".
function Get-ResolvedOwner {
    if ($script:_ResolvedOwner) { return $script:_ResolvedOwner }

    if (-not $script:_AuthDiagPrinted) {
        Write-Log "── gh auth diagnostic (once per run) ──" -Color DarkGray
        $authOut  = (gh auth status 2>&1 | Out-String).Trim()
        foreach ($l in ($authOut -split "`r?`n")) { Write-Log "  $l" -Color DarkGray }
        $viewer   = (gh api user --jq '.login' 2>&1 | Out-String).Trim()
        Write-Log "  gh api user → '[$viewer]'" -Color DarkGray
        Write-Log "  KANBAN_PROJECT_OWNER = '[$KanbanProjectOwner]' (length=$($KanbanProjectOwner.Length))" -Color DarkGray
        $script:_AuthDiagPrinted = $true
    }

    if ($KanbanProjectOwner) {
        $script:_ResolvedOwner = $KanbanProjectOwner
        return $KanbanProjectOwner
    }
    Write-Log "  ⚠️ KANBAN_PROJECT_OWNER not configured — run: task setup" -Color Yellow
    return $null
}

# Retries transient GraphQL/5xx failures from `gh project ...` calls. GitHub's
# Projects v2 GraphQL endpoint occasionally returns "Something went wrong" — these
# clear within seconds.
function Invoke-GhProjectRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Block,
        [string]$Description = 'gh project',
        [int]$MaxAttempts = 3
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $out = & $Block
        if ($LASTEXITCODE -eq 0) { return $out }
        $text = ($out | Out-String)
        $isTransient = $text -match 'GraphQL: Something went wrong|HTTP 5\d\d|Bad gateway|service unavailable|timeout|i/o timeout'
        if (-not $isTransient -or $attempt -eq $MaxAttempts) { return $out }
        $delayMs = [int](500 * [Math]::Pow(2, $attempt - 1))
        Write-Log "  ⚠️ $Description transient failure (attempt $attempt/$MaxAttempts) — retrying in ${delayMs}ms" -Color DarkYellow
        Start-Sleep -Milliseconds $delayMs
    }
}

function Get-ProjectId {
    if ($script:_CachedProjectId) { return $script:_CachedProjectId }
    if ($script:_ProjectIdFailed) { return $null }

    if ($env:KANBAN_PROJECT_ID) {
        # Use the setup-time resolved node ID — avoids a gh project list call every run.
        $script:_CachedProjectId = $env:KANBAN_PROJECT_ID
        return $script:_CachedProjectId
    }
    $owner = Get-ResolvedOwner
    if (-not $owner) { $script:_ProjectIdFailed = $true; return $null }
    $out = Invoke-GhProjectRetry -Description 'gh project list' -Block {
        gh project list --owner $owner --format json --jq `
            ".projects[] | select(.number == $KanbanProjectNumber) | .id" 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ gh project list failed: $($out.Trim())" -Color Yellow
        $script:_ProjectIdFailed = $true
        return $null
    }
    $script:_CachedProjectId = $out.Trim()
    return $script:_CachedProjectId
}

# Fetches all project items once per process and caches the result — one fetch
# serves every downstream lookup. $script:_CachedItems = $null means "not yet
# fetched"; an empty array means "fetched but board is empty". On failure the
# $script:_ItemsFailed flag short-circuits subsequent calls so one outage does
# not retrigger the 3-attempt retry per issue.
function Get-AllProjectItems {
    if ($null -ne $script:_CachedItems) { return $script:_CachedItems }
    if ($script:_ItemsFailed) { return $null }

    $owner = Get-ResolvedOwner
    if (-not $owner) { $script:_ItemsFailed = $true; return $null }
    $out = Invoke-GhProjectRetry -Description 'gh project item-list' -Block {
        gh project item-list $KanbanProjectNumber --owner $owner --format json --limit 200 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ gh project item-list failed: $($out.Trim())" -Color Yellow
        $script:_ItemsFailed = $true
        return $null
    }
    $parsed = $null
    try { $parsed = $out | ConvertFrom-Json } catch {
        Write-Log "  ⚠️ gh project item-list returned malformed JSON — skipping project-board ops this pass." -Color Yellow
        $script:_ItemsFailed = $true
        return $null
    }
    $script:_CachedItems = @($parsed.items)
    return $script:_CachedItems
}

function Get-ProjectStatus {
    param([int]$IssueNumber)
    $items = Get-AllProjectItems
    if ($null -eq $items) { return $null }
    $match = $items | Where-Object {
        $_.content.number -eq $IssueNumber -and $_.content.repository -eq $KanbanRepo
    } | Select-Object -First 1
    if (-not $match) { return $null }
    return $match.status
}

function Get-ProjectItemId {
    param([int]$IssueNumber)
    $items = Get-AllProjectItems
    if ($null -eq $items) { return $null }
    $match = $items | Where-Object {
        $_.content.number -eq $IssueNumber -and $_.content.repository -eq $KanbanRepo
    } | Select-Object -First 1
    if (-not $match) { return $null }
    return $match.id
}

# The board option id for one of the four lanes. Separate from $PipelineStates on
# purpose: that table declares the state machine, which is fixed, while these ids
# are repository variables written by `task setup` and read from the environment.
# Resolving them here means a transition reads whatever is configured when it runs
# — holding them in the table instead froze the values at module-load time, which
# silently turned every lane move into a no-op for any caller that set them after
# the import (every test in test_pipeline_label.py, and any re-setup mid-session).
function Get-LaneOptionId {
    param([string]$LaneName)
    switch ($LaneName) {
        'Backlog'      { $KanbanOpt_Backlog      }
        'Implementing' { $KanbanOpt_Implementing }
        'Review'       { $KanbanOpt_Review       }
        'Shipped'      { $KanbanOpt_Merged       }
        default        { '' }
    }
}

function Move-ToLane {
    param([int]$IssueNumber, [string]$OptionId, [string]$LaneName)
    if (-not $OptionId) {
        Write-Log "  Lane option ID not configured for '$LaneName' — skipping. Run: task setup" -Color Yellow
        return
    }
    $itemId    = Get-ProjectItemId -IssueNumber $IssueNumber
    if (-not $itemId -and (Add-IssueToBoard -IssueNumber $IssueNumber)) {
        $itemId = Get-ProjectItemId -IssueNumber $IssueNumber
    }
    $projectId = Get-ProjectId
    if (-not $itemId -or -not $projectId) {
        Write-Log "  Could not resolve project item for issue #$IssueNumber — skipping lane move." -Color Yellow
        return
    }

    # Skip the GraphQL write when the lane is already correct — saves one item-edit
    # per Set-AgentState call in steady state, and avoids pointless mutations
    # during transient GraphQL outages.
    $current = Get-ProjectStatus -IssueNumber $IssueNumber
    if ($current -eq $LaneName) {
        Write-Log "  Issue #$IssueNumber already in lane $LaneName — skipping." -Color DarkGray
        return
    }

    $ghArgs = @('project','item-edit','--id',$itemId,'--field-id',$KanbanStatusFieldId,'--project-id',$projectId,'--single-select-option-id',$OptionId)
    $out = Invoke-GhProjectRetry -Description 'gh project item-edit' -Block {
        gh @ghArgs 2>&1 | Out-String
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Lane move failed for issue #$IssueNumber → $LaneName : $($out.Trim())" -Color Yellow
    } else {
        Write-Log "  Issue #$IssueNumber → $LaneName" -Color DarkGray
        # Reflect the new lane in the cache so a subsequent same-pass call sees it.
        if ($null -ne $script:_CachedItems) {
            $cached = $script:_CachedItems | Where-Object {
                $_.content.number -eq $IssueNumber -and $_.content.repository -eq $KanbanRepo
            } | Select-Object -First 1
            if ($cached) { $cached.status = $LaneName }
        }
    }
}

# An issue opened in the GitHub UI or through the API never went through
# `task sync`, so it is not on the board: every lane move would skip it and refine
# could not set its estimate. Add it once, and record it in the item cache so the
# same pass sees it (with empty estimate/priority, which refine then fills in).
# It lands in Backlog — not started: being refined, or waiting on the owner — so it
# is never an item without a Status, which board views can hide.
function Add-IssueToBoard {
    param([int]$IssueNumber)
    if (Get-ProjectItemId -IssueNumber $IssueNumber) { return $true }
    # Board unreadable (not configured, or item-list failed) — nothing to add to.
    if ($KanbanProjectNumber -le 0 -or $null -eq $script:_CachedItems) { return $false }
    $owner = Get-ResolvedOwner
    if (-not $owner) { return $false }

    $url = "https://github.com/$KanbanRepo/issues/$IssueNumber"
    $out = Invoke-GhProjectRetry -Description 'gh project item-add' -Block {
        gh project item-add $KanbanProjectNumber --owner $owner --url $url --format json 2>&1 | Out-String
    }
    $itemId = $null
    if ($LASTEXITCODE -eq 0) { try { $itemId = ($out.Trim() | ConvertFrom-Json).id } catch {} }
    if (-not $itemId) {
        Write-Log "  ⚠️ Could not add issue #$IssueNumber to the project board: $($out.Trim())" -Color Yellow
        return $false
    }
    $script:_CachedItems = @($script:_CachedItems) + [pscustomobject]@{
        id       = $itemId
        content  = [pscustomobject]@{ number = $IssueNumber; repository = $KanbanRepo }
        status   = $null
        estimate = $null
        priority = $null
    }
    Write-Log "  Issue #$IssueNumber added to the project board." -Color DarkGray
    Move-ToLane -IssueNumber $IssueNumber -OptionId $KanbanOpt_Backlog -LaneName 'Backlog'
    return $true
}

# ── Project field helpers ─────────────────────────────────────────────────────

function Get-ProjectFieldValues {
    param([int]$IssueNumber)
    $items = Get-AllProjectItems
    if ($null -eq $items) { return $null }
    $match = $items | Where-Object {
        $_.content.number -eq $IssueNumber -and $_.content.repository -eq $KanbanRepo
    } | Select-Object -First 1
    if (-not $match) { return $null }
    return [pscustomobject]@{ estimate = $match.estimate; priority = $match.priority }
}

function Get-PriorityOptionId {
    param([string]$Priority)
    $vars = [System.Environment]::GetEnvironmentVariables('Process')
    foreach ($key in @($vars.Keys | Where-Object { $_ -match '^KANBAN_PRIORITY_OPT_' })) {
        if (($key -replace '^KANBAN_PRIORITY_OPT_', '') -ieq $Priority) { return $vars[$key] }
    }
    return $null
}

function Set-ProjectEstimate {
    param([int]$IssueNumber, [int]$Estimate)
    if (-not $KanbanEstimateFieldId) {
        Write-Log "  ⚠️ KANBAN_ESTIMATE_FIELD_ID not configured — run: task setup" -Color Yellow
        return
    }
    $itemId    = Get-ProjectItemId -IssueNumber $IssueNumber
    $projectId = Get-ProjectId
    if (-not $itemId -or -not $projectId) { return }
    $out = gh project item-edit --id $itemId --field-id $KanbanEstimateFieldId --project-id $projectId --number $Estimate 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not set Estimate field: $($out.Trim())" -Color Yellow
    } else {
        Write-Log "  Project field Estimate = $Estimate" -Color DarkGray
    }
}

function Set-ProjectPriority {
    param([int]$IssueNumber, [string]$Priority)
    if (-not $KanbanPriorityFieldId) {
        Write-Log "  ⚠️ KANBAN_PRIORITY_FIELD_ID not configured — run: task setup" -Color Yellow
        return
    }
    $optionId = Get-PriorityOptionId -Priority $Priority
    if (-not $optionId) {
        Write-Log "  ⚠️ No option ID for priority '$Priority' — check project options and run: task setup" -Color Yellow
        return
    }
    $itemId    = Get-ProjectItemId -IssueNumber $IssueNumber
    $projectId = Get-ProjectId
    if (-not $itemId -or -not $projectId) { return }
    $out = gh project item-edit --id $itemId --field-id $KanbanPriorityFieldId --project-id $projectId --single-select-option-id $optionId 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ⚠️ Could not set Priority field: $($out.Trim())" -Color Yellow
    } else {
        Write-Log "  Project field Priority = $Priority" -Color DarkGray
    }
}
