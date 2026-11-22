#Requires -Version 7.0
<#
    Journey.ps1 — what every journey starts from. Dot-sourced in a journey's BeforeAll.

    Imports the orchestrator module only when it is not loaded yet, so a Pester run
    loads it once, whatever the number of journeys. The import sees a sandbox
    repository name, the default branch `main` and none of the board settings, so
    the module never resolves anything against the real repository; the process
    environment is put back afterwards.

    Then loads the three fakes (tests/fakes/): GitHub, the engine, and the repo.
    Start-Journey gives one journey a fresh set of them, with `gh` and
    Invoke-EngineTask mocked in the module's scope, and sets the few settings a
    journey may lower (the required-checks ceiling); Stop-Journey puts them back and
    removes the repo.

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
}

. (Join-Path $PSScriptRoot '../fakes/GitHub.ps1')
. (Join-Path $PSScriptRoot '../fakes/Engine.ps1')
. (Join-Path $PSScriptRoot '../fakes/Repo.ps1')

# A fresh GitHub, engine and repository for one journey. Call it from BeforeEach or It:
# the mocks last for that Pester block.
#   -TestExit              the full test command's exit code, one per run (the last repeats)
#   -ChecksTimeoutSeconds  ship's ceiling on the wait for the required checks
#                          (RequiredChecksTimeoutSeconds) for this journey: 0 reads the
#                          checks once, so "not passed at the ceiling" ends at once
function Start-Journey {
    param(
        [string]$Name = '',
        [hashtable]$Files = @{ 'README.md' = "# Sandbox`n" },
        [int[]]$TestExit = @(0),
        [int]$ChecksTimeoutSeconds = -1
    )
    $repo = New-FakeRepo -Files $Files -TestExit $TestExit
    $null = New-FakeGitHub -Remote $repo.Remote -Journey $Name
    $null = New-FakeEngine
    Install-FakeGitHub
    Install-FakeEngine
    # The orchestrator's console log stays in its log file (in the repo's folder);
    # the run's output is Pester's. $env:JOURNEY_LOG shows it.
    if (-not $env:JOURNEY_LOG) { Mock Write-Host -ModuleName Orchestrator -MockWith { } }
    # Local CI is a setting of the machine that runs a journey, not of the journey.
    $repo | Add-Member -NotePropertyName LocalCi -NotePropertyValue $env:KANBAN_LOCAL_CI
    $env:KANBAN_LOCAL_CI = $null
    $repo | Add-Member -NotePropertyName ChecksTimeout -NotePropertyValue (Get-OrchestratorSetting -Name RequiredChecksTimeoutSeconds)
    if ($ChecksTimeoutSeconds -ge 0) { Set-OrchestratorSetting -Name RequiredChecksTimeoutSeconds -Value $ChecksTimeoutSeconds }
    return $repo
}

function Stop-Journey {
    param($Repo)
    if (-not $Repo) { return }
    $env:KANBAN_LOCAL_CI = $Repo.LocalCi
    Set-OrchestratorSetting -Name RequiredChecksTimeoutSeconds -Value $Repo.ChecksTimeout
    Remove-FakeRepo -Repo $Repo
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
function New-PlannedIssueBody {
    param([int]$Number, [string]$Goal = 'The glossary names the journeys.')
    $state = [ordered]@{
        issue_number      = $Number
        lane              = 'backlog'
        readiness         = [ordered]@{
            refined     = @{ done = $true; populated_by = 'self-grill-subagent'; timestamp = '2026-11-01T10:00:00Z' }
            architected = @{ done = $true; populated_by = 'architecture'; timestamp = '2026-11-01T10:01:00Z' }
            planned     = @{ done = $true; populated_by = 'plan (claude)'; timestamp = '2026-11-01T10:02:00Z' }
        }
        open_questions    = @()
        decided_questions = @()
        transitions       = @(@{ from = $null; to = 'backlog'; runtime = 'laptop'; timestamp = '2026-11-01T10:00:00Z' })
    } | ConvertTo-Json -Depth 6
    return @"
$(New-IssueBody -Goal $Goal)

<!-- AGENT-STATE:BEGIN -->
``````json
$state
``````
<!-- AGENT-STATE:END -->
"@
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
    param([string[]]$Paths = @('src/main.py', 'tests/test_main.py'))
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
# -Edits, runs a test and closes with its bullets. -Message scripts the commit message
# the run's commit asks for; leave it out when the run commits nothing.
# -RefusedEdits and -During go to the fake engine as they are (tests/fakes/Engine.ps1).
function Add-ImplementRun {
    param(
        [Parameter(Mandatory)][hashtable]$Edits,
        [string]$Message = '',
        [string[]]$RefusedEdits = @(),
        [scriptblock]$During = $null
    )
    $first = @($Edits.Keys | Sort-Object)[0]
    $calls = @(@{ Name = 'Read'; Input = @{ file_path = $first } }) +
             @($Edits.Keys | Sort-Object | ForEach-Object { @{ Name = 'Edit'; Input = @{ file_path = $_ } } }) +
             @(@{ Name = 'Bash'; Input = @{ command = 'uv run pytest tests/test_main.py' } })
    $files = ($Edits.Keys | Sort-Object | ForEach-Object { "- ``$_`` — changed" }) -join "`n"
    Add-EngineResult -Task ImplementSmall -Edits $Edits -ToolCalls $calls -RefusedEdits $RefusedEdits -During $During `
        -Reply "$files`n- Left undone: none`n- Issues discovered: none"
    if ($Message) { Add-EngineResult -Task CommitMessage -Reply $Message }
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
