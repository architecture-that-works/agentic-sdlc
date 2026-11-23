#Requires -Version 7.0
<#
    Journey.ps1 — what every journey starts from. Dot-sourced in a journey's BeforeAll.

    Imports the orchestrator module only when it is not loaded yet, so a Pester run
    loads it once, whatever the number of journeys. The import sees a sandbox
    repository name, the default branch `main` and none of the board settings, so
    the module never resolves anything against the real repository; the process
    environment is put back afterwards. The import reads no file. It also sets a
    recording-only breakpoint on every exported function, so the export-reach report
    (ExportReach.Tests.ps1, run last) knows which ones the journeys and tables reached.

    Then loads the fakes (tests/fakes/): GitHub, the engine, the repo, and the stand-in
    CLI that the engine adapter's own tables run against.
    Start-Journey gives one journey a fresh set of them, with `gh` and
    Invoke-EngineTask mocked in the module's scope, clears every setting of the
    machine it runs on (the KANBAN_* variables, the repository owner) and the board
    the module read in an earlier journey, and sets the few settings a journey may
    lower (the required-checks ceiling); Stop-Journey puts them back and removes the
    repo. A journey that needs a board states it: Set-JourneyBoard.

    Not a test file (no .Tests.ps1): Pester never runs it on its own. No top-level
    param() (ADR-013).
#>

if (-not (Get-Module Orchestrator)) {
    $saved = @{}
    $names = @('GITHUB_REPOSITORY', 'GITHUB_DEFAULT_BRANCH') +
             @([System.Environment]::GetEnvironmentVariables('Process').Keys | Where-Object { "$_" -like 'KANBAN_*' })
    foreach ($n in $names) { $saved[$n] = [System.Environment]::GetEnvironmentVariable($n) }
    foreach ($n in $names) { [System.Environment]::SetEnvironmentVariable($n, $null) }
    $env:GITHUB_REPOSITORY     = 'octo/sandbox'
    $env:GITHUB_DEFAULT_BRANCH = 'main'
    try {
        Import-Module (Join-Path $PSScriptRoot '../../.github/orchestrator/Orchestrator.psd1') -DisableNameChecking -Global
    } finally {
        foreach ($n in $names) { [System.Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    }
    # Each call of an exported function is recorded by name, wherever it comes from — a
    # journey, a table, a Command, or the module itself.
    foreach ($name in @((Get-Module Orchestrator).ExportedFunctions.Keys)) {
        $record = [scriptblock]::Create(
            "if (`$null -eq `$global:OrchestratorExportReach) { `$global:OrchestratorExportReach = @{} }; `$global:OrchestratorExportReach['$name'] = `$true")
        $null = Set-PSBreakpoint -Command $name -Action $record
    }
}

. (Join-Path $PSScriptRoot '../fakes/GitHub.ps1')
. (Join-Path $PSScriptRoot '../fakes/Engine.ps1')
. (Join-Path $PSScriptRoot '../fakes/Repo.ps1')
. (Join-Path $PSScriptRoot '../fakes/Cli.ps1')

# A fresh GitHub, engine and repository for one journey. Call it from BeforeEach or It:
# the mocks last for that Pester block.
#   -TestExit              the full test command's exit code, one per run (the last repeats)
#   -ChecksTimeoutSeconds  ship's ceiling on the wait for the required checks
#                          (RequiredChecksTimeoutSeconds) for this journey: 0 reads the
#                          checks once, so "not passed at the ceiling" ends at once
#   -RealEngine            leave Invoke-EngineTask unmocked: the engine adapter runs,
#                          against whatever `claude` the table stands in
function Start-Journey {
    param(
        [string]$Name = '',
        [hashtable]$Files = @{ 'README.md' = "# Sandbox`n" },
        [int[]]$TestExit = @(0),
        [int]$ChecksTimeoutSeconds = -1,
        [switch]$RealEngine
    )
    $global:OrchestratorJourneyStarts = 1 + [int]$global:OrchestratorJourneyStarts
    $repo = New-FakeRepo -Files $Files -TestExit $TestExit
    $null = New-FakeGitHub -Remote $repo.Remote -Journey $Name
    $null = New-FakeEngine
    Install-FakeGitHub
    if (-not $RealEngine) { Install-FakeEngine }
    # The orchestrator's console log stays in its log file (in the repo's folder);
    # the run's output is Pester's. $env:JOURNEY_LOG shows it.
    if (-not $env:JOURNEY_LOG) { Mock Write-Host -ModuleName Orchestrator -MockWith { } }
    # The board, local CI and the rest of the KANBAN_* settings are settings of the
    # machine that runs a journey, not of the journey, and so are the workflow run a
    # CI runner is in and its job summary: cleared here, put back by Stop-Journey. So
    # is what the module read from an earlier journey's board.
    $machine = @{}
    $names = @('GITHUB_REPOSITORY_OWNER', 'GITHUB_RUN_ID', 'GITHUB_STEP_SUMMARY') +
             @([System.Environment]::GetEnvironmentVariables('Process').Keys | Where-Object { "$_" -like 'KANBAN_*' })
    foreach ($n in $names) {
        $machine[$n] = [System.Environment]::GetEnvironmentVariable($n)
        [System.Environment]::SetEnvironmentVariable($n, $null)
    }
    $repo | Add-Member -NotePropertyName Machine -NotePropertyValue $machine
    Reset-JourneyBoardCache
    $repo | Add-Member -NotePropertyName ChecksTimeout -NotePropertyValue (Get-OrchestratorSetting -Name RequiredChecksTimeoutSeconds)
    if ($ChecksTimeoutSeconds -ge 0) { Set-OrchestratorSetting -Name RequiredChecksTimeoutSeconds -Value $ChecksTimeoutSeconds }
    return $repo
}

function Stop-Journey {
    param($Repo)
    if (-not $Repo) { return }
    foreach ($n in @([System.Environment]::GetEnvironmentVariables('Process').Keys | Where-Object { "$_" -like 'KANBAN_*' })) {
        [System.Environment]::SetEnvironmentVariable($n, $null)
    }
    foreach ($n in $Repo.Machine.Keys) { [System.Environment]::SetEnvironmentVariable($n, $Repo.Machine[$n]) }
    Reset-JourneyBoardCache
    Set-OrchestratorSetting -Name RequiredChecksTimeoutSeconds -Value $Repo.ChecksTimeout
    Remove-FakeRepo -Repo $Repo
}

# States the fake GitHub's board (Get-FakeBoardSettings) in the process environment, as
# `task setup` leaves it in .env: the project, its Status field and lanes, and the
# Estimate and Priority fields. Stop-Journey clears it.
function Set-JourneyBoard {
    $settings = Get-FakeBoardSettings
    foreach ($k in $settings.Keys) { [System.Environment]::SetEnvironmentVariable($k, $settings[$k]) }
}

# What the module read from a board — its items and its id — lasts for one process in
# a real run; between journeys it is forgotten, so each one reads its own board.
function Reset-JourneyBoardCache {
    & (Get-Module Orchestrator) {
        $script:_CachedItems = $null; $script:_CachedProjectId = $null
        $script:_ProjectIdFailed = $false; $script:_ItemsFailed = $false
    }
}

# One value of the orchestrator's settings table ($OrchestratorConfig, lib/Config.ps1),
# so a journey reads MaxRetries or the required checks from the one place they are written.
function Get-OrchestratorSetting {
    param([Parameter(Mandatory)][string]$Name)
    return & (Get-Module Orchestrator) { param($n)
        if (-not $OrchestratorConfig.Contains($n)) { throw "The orchestrator has no setting '$n'." }
        $OrchestratorConfig[$n] } $Name
}

function Set-OrchestratorSetting {
    param([Parameter(Mandatory)][string]$Name, $Value)
    & (Get-Module Orchestrator) { param($n, $v) $OrchestratorConfig[$n] = $v } $Name $Value
}

# Fails the journey on any call a fake did not expect: a gh call the fake GitHub does
# not know, an engine Task with nothing scripted, a scripted result never used.
function Assert-JourneyClean {
    Assert-FakeGitHubClean
    Assert-FakeEngineClean
}

# What happened to an issue, for an assertion's -Because: its pipeline comments in
# order, then any call a fake did not expect.
function Get-JourneyStory {
    param([Parameter(Mandatory)][int]$Issue)
    $lines = @(Get-FakeComments -Issue $Issue | ForEach-Object { "  $(($_.Body -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' / ')" })
    $lines += @($global:FakeGitHub.Unknown) + @($global:FakeEngine.Unknown) | ForEach-Object { "  ! $_" }
    return "the issue's timeline was:`n$($lines -join "`n")`n"
}

# ── Starting material ─────────────────────────────────────────────────────────

# An issue body with every heading of the issue template, as the owner writes it.
function New-IssueBody {
    param([string]$Goal = 'The home page greets a visitor by name.')
    return @"
**Goal**: $Goal
**Description**: The greeting is fixed today; visitors asked to be greeted by name.
**Requirements**:
1. The greeting names the visitor when the request carries a name.
**Acceptance Criteria**:
- [ ] A request with a name gets a greeting with that name.
"@
}

# An issue body that has been refined, architected and planned, with nothing open:
# what refine leaves behind when it queues an issue at agent:backlog.
#   -Unplanned  refined only: architect and plan have not run (a refine that stopped)
#   -State      further carrier fields, e.g. @{ paused_until = '<iso time>' }
function New-PlannedIssueBody {
    param([int]$Number, [string]$Goal = 'The glossary names the journeys.', [switch]$Unplanned, [hashtable]$State = @{})
    $carrier = [ordered]@{
        issue_number      = $Number
        lane              = 'backlog'
        readiness         = [ordered]@{
            refined     = @{ done = $true; populated_by = 'self-grill-subagent'; timestamp = '2026-11-01T10:00:00Z' }
            architected = @{ done = -not $Unplanned; populated_by = 'architecture'; timestamp = '2026-11-01T10:01:00Z' }
            planned     = @{ done = -not $Unplanned; populated_by = 'plan (claude)'; timestamp = '2026-11-01T10:02:00Z' }
        }
        open_questions    = @()
        decided_questions = @()
        transitions       = @(@{ from = $null; to = 'backlog'; runtime = 'laptop'; timestamp = '2026-11-01T10:00:00Z' })
    }
    foreach ($key in $State.Keys) { $carrier[$key] = $State[$key] }
    $json = $carrier | ConvertTo-Json -Depth 6
    return @"
$(New-IssueBody -Goal $Goal)

<!-- AGENT-STATE:BEGIN -->
``````json
$json
``````
<!-- AGENT-STATE:END -->
"@
}

# The issue's carrier — the AGENT-STATE block of its body, as the owner can read it —
# as an object; $null when the body holds none.
function Get-CarrierState {
    param([Parameter(Mandatory)][int]$Number)
    $body = (Get-FakeIssue $Number).Body
    if ($body -notmatch '(?s)<!-- AGENT-STATE:BEGIN -->\s*```json\s*(?<json>.+?)\s*```\s*<!-- AGENT-STATE:END -->') { return $null }
    return $Matches['json'] | ConvertFrom-Json
}

# An issue body in the shape of the issue template: one section per heading the
# orchestrator's template reader gives (Get-IssueHeadings), in the template's style.
function New-TemplateBody {
    param([string]$Text = 'The home page greets a visitor by name.')
    $lines = foreach ($h in @(Get-IssueHeadings)) {
        switch ($h.Style) {
            'inline'   { "**$($h.Name)**: $Text" }
            'numbered' { "**$($h.Name)**:`n1. $Text" }
            'checkbox' { "**$($h.Name)**:`n- [ ] $Text" }
            default    { "**$($h.Name)**:`n- $Text" }
        }
    }
    return ($lines -join "`n")
}

# The self-grill's answer: an Agent Brief and the questions, as JSON text.
function New-GrillReply {
    param([object[]]$Open = @())
    return ([ordered]@{
        agent_brief       = [ordered]@{
            feature_name      = 'greet-by-name'
            problem_statement = 'A visitor wants to be greeted by name.'
            interfaces        = @('A request with a name answers with a greeting that names the visitor.')
            constraints       = @('Standard library only.')
            out_of_scope      = @('Remembering a visitor between requests.')
            tracer_bullet     = 'One request with a name gets a greeting with that name.'
        }
        open_questions    = @($Open)
        decided_questions = @([ordered]@{
            text = 'Where is the name read from?'; raised_by = 'self-grill-subagent'
            decided_by = 'self-grill-subagent'; decision = 'The query string — evidence: the handler reads the query.'
        })
    } | ConvertTo-Json -Depth 6 -Compress)
}

function New-PlanReply {
    param([string[]]$Paths = @('src/main.py', 'tests/app/test_main.py'))
    return ([ordered]@{
        plan_markdown   = "1. Read the name from the query.`n2. Put it in the greeting.`n3. Test both."
        paths_to_modify = @($Paths)
    } | ConvertTo-Json -Compress)
}

# The files a build journey's repository starts from: a README and a glossary.
function Get-JourneyFiles {
    return @{ 'README.md' = "# Sandbox`n"; 'CONTEXT.md' = (Get-GlossaryText) }
}

# CONTEXT.md as the journey's repository has it, with -Rows added to its glossary.
# CONTEXT.md is a governance file: a change to it is held for the owner.
function Get-GlossaryText {
    param([string[]]$Rows = @())
    $text = "# CONTEXT.md`n`n## Glossary`n`n| Term | Definition |`n|---|---|`n"
    foreach ($row in $Rows) { $text += "$row`n" }
    return $text
}

# One implement run: the agent reads the first file it edits, edits every file in
# -Edits, runs a test and closes with its checked answer — -Implemented, -LeftUndone
# and -IssuesDiscovered, the three lists of the closing note (one item naming the
# edited files, and two empty lists, unless given). -Message scripts the commit message
# the run's commit asks for; leave it out when the run commits nothing.
# -RefusedEdits and -During go to the fake engine as they are (tests/fakes/Engine.ps1).
# -Task is the implement task the run is scripted for (ImplementSmall unless the estimate
# makes it ImplementLarge).
function Add-ImplementRun {
    param(
        [Parameter(Mandatory)][hashtable]$Edits,
        [ValidateSet('ImplementSmall', 'ImplementLarge')][string]$Task = 'ImplementSmall',
        [string]$Message = '',
        [string[]]$RefusedEdits = @(),
        [scriptblock]$During = $null,
        [string[]]$Implemented = @(),
        [string[]]$LeftUndone = @(),
        [string[]]$IssuesDiscovered = @()
    )
    $first = @($Edits.Keys | Sort-Object)[0]
    $calls = @(@{ Name = 'Read'; Input = @{ file_path = $first } }) +
             @($Edits.Keys | Sort-Object | ForEach-Object { @{ Name = 'Edit'; Input = @{ file_path = $_ } } }) +
             @(@{ Name = 'Bash'; Input = @{ command = 'uv run pytest tests/app/test_main.py' } })
    if (-not $PSBoundParameters.ContainsKey('Implemented')) {
        $Implemented = @("Changed $((@($Edits.Keys | Sort-Object)) -join ', ')")
    }
    Add-EngineResult -Task $Task -Edits $Edits -ToolCalls $calls -RefusedEdits $RefusedEdits -During $During `
        -Answer (New-ClosingNote -Implemented $Implemented -LeftUndone $LeftUndone -IssuesDiscovered $IssuesDiscovered)
    if ($Message) { Add-EngineResult -Task CommitMessage -Reply $Message }
}

# The implement task's checked answer: the closing note's three lists, as the engine
# returns it for .agents/skills/implement/answer.schema.json.
function New-ClosingNote {
    param([string[]]$Implemented = @(), [string[]]$LeftUndone = @(), [string[]]$IssuesDiscovered = @())
    return @{ implemented = @($Implemented); left_undone = @($LeftUndone); issues_discovered = @($IssuesDiscovered) }
}

# One queued issue through one implement → review → ship round of the conductor: the
# agent edits -Edits and commits, the review approves. Returns the issue's pull request.
function Invoke-BuildRound {
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][hashtable]$Edits, [string]$Title = 'Describe the decisions')
    Add-FakeIssue -Number $Number -Title $Title -Body (New-PlannedIssueBody -Number $Number) -Labels @('agent:backlog')
    Add-ImplementRun -Edits $Edits -Message "docs(#$Number): $($Title.ToLower())"
    Add-ReviewVerdict
    Invoke-Orchestration -IssueNumber $Number -From implement
    return @($global:FakeGitHub.PullRequests | Where-Object { $_.Head -like "feature/$Number-*" })[0]
}

# The review's checked answer. -During goes to the fake engine as it is.
function Add-ReviewVerdict {
    param(
        [ValidateSet('approved', 'rejected')][string]$Verdict = 'approved',
        [string]$Report = 'Every acceptance criterion is met.',
        [scriptblock]$During = $null
    )
    Add-EngineResult -Task Review -Answer @{ verdict = $Verdict; report = $Report } -During $During
}

# A queued issue held for the owner: one implement → review → ship run through the
# conductor on a change to the glossary (a governance file). Returns its pull request.
function New-HeldIssue {
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Row)
    Add-FakeIssue -Number $Number -Title $Title -Body (New-PlannedIssueBody -Number $Number) -Labels @('agent:backlog')
    Add-ImplementRun -Edits @{ 'CONTEXT.md' = (Get-GlossaryText -Rows $Row) } -Message "docs(#$Number): $($Title.ToLower())"
    Add-ReviewVerdict
    Invoke-Orchestration -IssueNumber $Number -From implement
    $label = Get-FakePipelineLabel $Number
    if ($label -ne 'human:approval') { throw "New-HeldIssue: #$Number ended at '$label', not human:approval.`n$(Get-JourneyStory $Number)" }
    return @($global:FakeGitHub.PullRequests | Where-Object { $_.Head -like "feature/$Number-*" })[0]
}
