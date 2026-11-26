#Requires -Version 7.0
<#
    Recovery journeys — how the workflow gets a stalled issue moving again: an issue
    whose label claims work nobody is doing, a spent usage allowance (at the start of a
    run, or while refine, review or the answer check runs) and the resume that follows,
    and an owner's comment on a failed issue or on one the agent holds.

    Each journey enters through a public entry point the workflow itself calls: the
    hourly warden (Invoke-Reconciliation), the resume of due pauses
    (Resume-PausedIssues), or the conductor (Invoke-Orchestration), which pauses an
    issue when the engine reports a spent allowance and routes an owner comment. Time
    passes through the fakes: an issue's last activity is set in the past
    (Set-FakeIssueIdle), and a pause is seeded with its resume time. Every limit — the
    stuck time, the re-entry cap, the longest pause — is read from the orchestrator's
    settings, and what counts as held by a person from $PipelineStates.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')

    # The pipeline states a person holds, read from the one label table.
    function Get-HumanHeldStates {
        return & (Get-Module Orchestrator) { @($PipelineStates.Keys | Where-Object { $PipelineStates[$_].Holder -eq 'human' }) }
    }

    # While a stage's model call runs, the allowance runs out: the engine's next readiness
    # check reports it. Pass as -During of that call.
    $script:SpendAllowance = { Add-EngineResult -Task EngineCheck -Outcome failed -Output (Get-EngineUsageLimitText) }

    # Asserts issue -Number is paused by a spent allowance, with no attempt counted.
    function Assert-Paused {
        param([int]$Number)
        Get-FakePipelineLabel $Number | Should -Be 'agent:paused' -Because (Get-JourneyStory $Number)
        @(Get-FakeCommentHeadings $Number)[-1] | Should -BeLike '🤖⏳ Paused — the Claude usage limit is reached. Work resumes after *'
        (Get-CarrierState $Number).paused_until | Should -Not -BeNullOrEmpty
        @(Get-FakeCommentHeadings $Number | Where-Object { $_ -like '🤖🔁*' -or $_ -like '🤖❌*' }) | Should -BeNullOrEmpty -Because 'a pause is not a failure'
    }

    # A refined issue that waits on the owner's answers to two questions.
    function New-WaitingIssueBody {
        param([int]$Number, [hashtable]$State = @{})
        $open = @(
            [ordered]@{ id = 1; text = 'Greet by first name or full name?'; raised_by = 'self-grill-subagent'
                decision = 'First name — because it reads friendlier'; alternatives = @('Full name — formal') }
            [ordered]@{ id = 2; text = 'What does a visitor without a name see?'; raised_by = 'self-grill-subagent'
                decision = 'The greeting of today — nothing changes for them'; alternatives = @('An error — strict') }
        )
        return New-PlannedIssueBody -Number $Number -Unplanned -State (@{ open_questions = $open } + $State)
    }
}

Describe 'Recovery journey' {
    BeforeEach { $script:repo = Start-Journey -Name "Recovery: $($____Pester.CurrentTest.Name)" }
    AfterEach { Stop-Journey $script:repo }

    It 're-enters an issue nobody is working on after the stuck time, and hands it to the owner after the allowed re-entries' {
        $stuckAfter = Get-OrchestratorSetting -Name StuckAfterMinutes
        $cap        = Get-OrchestratorSetting -Name MaxReconcile
        Add-FakeIssue -Number 40 -Title 'Name the warden' -Body (New-PlannedIssueBody -Number 40) -Labels @('agent:implementing')

        # Inside the stuck time the label is taken at its word: a run may still be on it.
        $null = Invoke-Reconciliation
        Get-FakePipelineLabel 40 | Should -Be 'agent:implementing'
        Get-FakeComments 40 | Should -BeNullOrEmpty

        # Silent past the stuck time: nobody is implementing it. A planned issue goes back
        # to agent:backlog, whose label event starts implement again.
        Set-FakeIssueIdle -Number 40 -Minutes ($stuckAfter + 1)
        $null = Invoke-Reconciliation
        Get-FakePipelineLabel 40 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 40)
        @(Get-FakeCommentHeadings 40)[-1] | Should -BeLike '· restarting from implement (no activity for * min at agent:implementing)'
        Get-FakeDispatches | Should -BeNullOrEmpty

        # Still nothing happens: agent:backlog is already the go signal, so the warden
        # dispatches the implement job — as often as the cap allows.
        foreach ($pass in 1..$cap) {
            Set-FakeIssueIdle -Number 40 -Minutes ($stuckAfter + 1)
            $null = Invoke-Reconciliation
            Get-FakePipelineLabel 40 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 40)
            @(Get-FakeCommentHeadings 40)[-1] | Should -BeLike '· re-dispatching implement (no activity for * min at agent:backlog)'
            $dispatches = @(Get-FakeDispatches)
            $dispatches.Count | Should -Be $pass
            $dispatches[-1].Stage | Should -Be 'implement'
            $dispatches[-1].Issue | Should -Be 40
        }

        # One stall too many: the warden stops re-entering and hands the issue to the owner.
        Set-FakeIssueIdle -Number 40 -Minutes ($stuckAfter + 1)
        $null = Invoke-Reconciliation
        Get-FakePipelineLabel 40 | Should -Be 'agent:failed' -Because (Get-JourneyStory 40)
        @(Get-FakeCommentHeadings 40)[-1] | Should -BeLike '🤖❌ Stuck at **agent:backlog** and re-entry is not working — needs you'
        (Get-FakeComments 40)[-1].Body | Should -Match "restarted it $cap time\(s\)"
        @(Get-FakeDispatches).Count | Should -Be $cap

        # Held by the owner now: later passes leave it alone.
        $comments = @(Get-FakeComments 40).Count
        Set-FakeIssueIdle -Number 40 -Minutes ($stuckAfter * 10)
        $null = Invoke-Reconciliation
        Get-FakePipelineLabel 40 | Should -Be 'agent:failed'
        @(Get-FakeComments 40).Count | Should -Be $comments
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'restarts refine for a stalled issue that was never planned' {
        $stuckAfter = Get-OrchestratorSetting -Name StuckAfterMinutes
        Add-FakeIssue -Number 41 -Title 'Name the warden' -Body (New-PlannedIssueBody -Number 41 -Unplanned) -Labels @('agent:refining') -IdleMinutes ($stuckAfter + 1)

        $null = Invoke-Reconciliation

        # Never sent to agent:backlog, where the readiness gate would refuse it: its label is
        # cleared and refine is dispatched again.
        Get-FakePipelineLabel 41 | Should -BeNullOrEmpty -Because (Get-JourneyStory 41)
        @(Get-FakeCommentHeadings 41) | Should -Be @('· restarting refine (no activity for ' + "$($stuckAfter + 1)" + ' min at agent:refining)')
        $dispatch = @(Get-FakeDispatches)
        $dispatch.Count | Should -Be 1
        $dispatch[0].Stage | Should -Be 'refine'
        $dispatch[0].Issue | Should -Be 41
        Assert-JourneyClean
    }

    It 'caps the re-entries of an issue refine never claimed, though it had no carrier yet' {
        $stuckAfter = Get-OrchestratorSetting -Name StuckAfterMinutes
        $cap        = Get-OrchestratorSetting -Name MaxReconcile
        Add-FakeIssue -Number 62 -Title 'Greet the visitor by name' -Body (New-IssueBody)

        # No label: the refine run its `opened` event started died before it labelled anything.
        foreach ($pass in 1..$cap) {
            Set-FakeIssueIdle -Number 62 -Minutes ($stuckAfter + 1)
            $null = Invoke-Reconciliation
            Get-FakePipelineLabel 62 | Should -BeNullOrEmpty -Because (Get-JourneyStory 62)
            @(Get-FakeCommentHeadings 62)[-1] | Should -BeLike '· restarting refine (no activity for * min at (none))'
            @(Get-FakeDispatches | Where-Object { $_.Stage -eq 'refine' -and $_.Issue -eq 62 }).Count | Should -Be $pass
        }

        Set-FakeIssueIdle -Number 62 -Minutes ($stuckAfter + 1)
        $null = Invoke-Reconciliation
        Get-FakePipelineLabel 62 | Should -Be 'agent:failed' -Because (Get-JourneyStory 62)
        @(Get-FakeCommentHeadings 62)[-1] | Should -BeLike '🤖❌ Stuck at **(none)** and re-entry is not working — needs you'
        @(Get-FakeDispatches).Count | Should -Be $cap
        Assert-JourneyClean
    }

    It 'never touches a state a person holds, however long it waits' {
        $stuckAfter = Get-OrchestratorSetting -Name StuckAfterMinutes
        $held = @(Get-HumanHeldStates)
        $held.Count | Should -BeGreaterThan 0
        $number = 50
        $bodies = @{}
        foreach ($label in $held) {
            Add-FakeIssue -Number $number -Title "Held at $label" -Body (New-PlannedIssueBody -Number $number) -Labels @($label) -IdleMinutes ($stuckAfter * 100)
            $bodies[$number] = (Get-FakeIssue $number).Body
            $number++
        }

        $null = Invoke-Reconciliation

        $number = 50
        foreach ($label in $held) {
            Get-FakePipelineLabel $number | Should -Be $label -Because (Get-JourneyStory $number)
            Get-FakeComments $number | Should -BeNullOrEmpty
            (Get-FakeIssue $number).Body | Should -Be $bodies[$number]
            $number++
        }
        Get-FakeTransitions | Should -BeNullOrEmpty
        Get-FakeDispatches | Should -BeNullOrEmpty
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'pauses an issue on a spent usage allowance until the time the engine names, never longer than the longest pause' {
        $longest = Get-OrchestratorSetting -Name MaxPauseHours
        $before  = (Get-Date).ToUniversalTime()
        $soon    = $before.AddHours(1).AddMinutes(17)
        $late    = $before.AddHours($longest + 24)
        Add-FakeIssue -Number 42 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        Add-FakeIssue -Number 43 -Title 'Greet the visitor by title' -Body (New-IssueBody)

        Add-EngineResult -Task EngineCheck -Outcome failed -Output (Get-EngineUsageLimitText -ResetsAt $soon)
        $null = Invoke-Orchestration -IssueNumber 42 -From refine
        Add-EngineResult -Task EngineCheck -Outcome failed -Output (Get-EngineUsageLimitText -ResetsAt $late)
        $null = Invoke-Orchestration -IssueNumber 43 -From refine
        $after = (Get-Date).ToUniversalTime()

        foreach ($n in 42, 43) {
            Get-FakePipelineLabel $n | Should -Be 'agent:paused' -Because (Get-JourneyStory $n)
            $until = ([datetime](Get-CarrierState $n).paused_until).ToUniversalTime()
            @(Get-FakeCommentHeadings $n) | Should -HaveCount 1
            @(Get-FakeCommentHeadings $n)[0] | Should -BeLike "🤖⏳ Paused*resumes after $($until.ToString('yyyy-MM-dd HH:mm')) UTC*"
            # A pause is not a failure: no attempt counted, no stage named.
            (Get-CarrierState $n).PSObject.Properties['attempts'] | Should -BeNullOrEmpty
            (Get-FakeIssue $n).Body | Should -Not -Match '## Attempts'
            $until | Should -BeLessOrEqual $after.AddHours($longest)
        }
        # The time the engine names, to the second.
        ([datetime](Get-CarrierState 42).paused_until).ToUniversalTime().ToString('s') | Should -Be $soon.ToString('s')
        # A later reset time is cut to the longest pause.
        ([datetime](Get-CarrierState 43).paused_until).ToUniversalTime() | Should -BeGreaterOrEqual $before.AddHours($longest).AddSeconds(-1)
        # Only the readiness check ran: no stage reached the engine.
        @(Get-FakeEngineCalls | Where-Object Task -ne 'EngineCheck') | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'resumes a paused issue once its time has passed, and leaves one that is not due' {
        $now = (Get-Date).ToUniversalTime()
        $past   = @{ paused_until = $now.AddMinutes(-5).ToString('o') }
        $future = @{ paused_until = $now.AddHours(1).ToString('o') }
        Add-FakeIssue -Number 44 -Title 'Greet the visitor by name' -Body (New-PlannedIssueBody -Number 44 -State $past) -Labels @('agent:paused')
        Add-FakeIssue -Number 45 -Title 'Greet the visitor by title' -Body (New-PlannedIssueBody -Number 45 -Unplanned -State $past) -Labels @('agent:paused')
        Add-FakeIssue -Number 46 -Title 'Greet the visitor in Dutch' -Body (New-PlannedIssueBody -Number 46 -State $future) -Labels @('agent:paused')

        Resume-PausedIssues

        # Planned: back to agent:backlog, whose label event starts implement.
        Get-FakePipelineLabel 44 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 44)
        @(Get-FakeCommentHeadings 44) | Should -Be @('· restarting from implement (usage limit lifted)')
        (Get-CarrierState 44).PSObject.Properties['paused_until'] | Should -BeNullOrEmpty
        # Not planned: refine runs again, and reads any answer that came during the pause.
        Get-FakePipelineLabel 45 | Should -BeNullOrEmpty -Because (Get-JourneyStory 45)
        @(Get-FakeCommentHeadings 45) | Should -Be @('· restarting refine (usage limit lifted)')
        $dispatch = @(Get-FakeDispatches)
        $dispatch.Count | Should -Be 1
        $dispatch[0].Stage | Should -Be 'refine'
        $dispatch[0].Issue | Should -Be 45
        # Not due yet: still paused, nothing said.
        Get-FakePipelineLabel 46 | Should -Be 'agent:paused'
        Get-FakeComments 46 | Should -BeNullOrEmpty
        (Get-CarrierState 46).paused_until | Should -Not -BeNullOrEmpty
        # One probe of the engine before resuming anything.
        @(Get-FakeEngineCalls).Task | Should -Be @('EngineCheck')
        Assert-JourneyClean
    }

    It 'resumes a due pause at the start of any run, through the conductor' {
        $past = @{ paused_until = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o') }
        Add-FakeIssue -Number 47 -Title 'Greet the visitor by name' -Body (New-PlannedIssueBody -Number 47 -State $past) -Labels @('agent:paused')
        Add-FakeIssue -Number 48 -Title 'Name the warden' -Body (New-PlannedIssueBody -Number 48) -Labels @('agent:implementing')
        Add-FakeComment -Issue 48 -Body 'How is this going?'

        $null = Invoke-Orchestration -IssueNumber 48 -From comment

        Get-FakePipelineLabel 47 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 47)
        @(Get-FakeCommentHeadings 47) | Should -Be @('· restarting from implement (usage limit lifted)')
        Assert-JourneyClean
    }

    It 'pauses an issue the owner holds, or one that failed, when a comment comes in while the allowance is spent' {
        Add-FakeIssue -Number 70 -Title 'Greet the visitor by name' -Body (New-PlannedIssueBody -Number 70) -Labels @('human:approval')
        Add-FakeComment -Issue 70 -Body 'Please also greet by title.'
        Add-FakeIssue -Number 71 -Title 'Greet the visitor by title' -Body (New-PlannedIssueBody -Number 71) -Labels @('agent:failed')
        Add-FakeComment -Issue 71 -Body 'Try again.'

        foreach ($n in 70, 71) {
            & $script:SpendAllowance
            $null = Invoke-Orchestration -IssueNumber $n -From comment
            Assert-Paused $n
        }
        # The owner's hold is kept for ship.
        (Get-CarrierState 70).approval_required | Should -BeTrue
        @(Get-FakeEngineCalls).Task | Should -Be @('EngineCheck', 'EngineCheck')
        Get-FakeDispatches | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'pauses a refine whose questioning stopped while the allowance was spent' {
        Add-FakeIssue -Number 72 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        Add-EngineResult -Task Refine -Outcome failed -During $script:SpendAllowance

        $null = Invoke-Orchestration -IssueNumber 72 -From refine

        Assert-Paused 72
        (Get-FakeIssue 72).Body | Should -Not -Match '## Attempts'
        Assert-JourneyClean
    }

    It 'pauses an implement round whose review stopped while the allowance was spent' {
        Add-FakeIssue -Number 73 -Title 'Describe the decisions' -Body (New-PlannedIssueBody -Number 73) -Labels @('agent:backlog')
        Add-ImplementRun -Edits @{ 'docs/decisions.md' = "# Decisions`n" } -Message 'docs(#73): describe the decisions'
        Add-EngineResult -Task Review -Outcome failed -During $script:SpendAllowance

        Invoke-Orchestration -IssueNumber 73 -From implement

        Assert-Paused 73
        # The work is kept on its pull request for the resumed round.
        @($global:FakeGitHub.PullRequests | Where-Object { $_.Head -like 'feature/73-*' -and $_.State -eq 'OPEN' }).Count | Should -Be 1
        Assert-JourneyClean
    }

    It 'pauses an issue waiting on decisions when checking the owner''s reply stopped on a spent allowance' {
        Add-FakeIssue -Number 74 -Title 'Greet the visitor by name' -Body (New-WaitingIssueBody -Number 74) -Labels @('human:decision')
        Add-FakeComment -Issue 74 -Body 'ok'
        Add-EngineResult -Task Refine -Outcome failed -During $script:SpendAllowance

        $null = Invoke-Orchestration -IssueNumber 74 -From comment

        Assert-Paused 74
        # The questions stay open: the resumed refine reads the reply again.
        @((Get-CarrierState 74).open_questions).Count | Should -Be 2
        Assert-JourneyClean
    }

    It 'asks again for what is still open when a paused issue that waits on answers resumes' {
        $past = @{ paused_until = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o') }
        Add-FakeIssue -Number 75 -Title 'Greet the visitor by name' -Body (New-WaitingIssueBody -Number 75 -State $past) -Labels @('agent:paused')
        # The owner answered one question during the pause.
        Add-FakeComment -Issue 75 -Body '1A. Not sure about the second one yet.'

        Resume-PausedIssues
        Get-FakePipelineLabel 75 | Should -BeNullOrEmpty -Because (Get-JourneyStory 75)
        @(Get-FakeDispatches | Where-Object { $_.Stage -eq 'refine' -and $_.Issue -eq 75 }).Count | Should -Be 1

        # The dispatched refine run reads the reply.
        Add-EngineResult -Task Refine -Reply ([ordered]@{
            answers       = @(
                [ordered]@{ id = 1; status = 'answered'; decision = 'Greet by first name.' }
                [ordered]@{ id = 2; status = 'open'; follow_up = 'Pick A (the greeting of today) or B (an error).' }
            )
            new_questions = @()
        } | ConvertTo-Json -Depth 4 -Compress)
        $null = Invoke-Orchestration -IssueNumber 75 -From refine

        Get-FakePipelineLabel 75 | Should -Be 'human:decision' -Because (Get-JourneyStory 75)
        @(Get-FakeCommentHeadings 75)[-1] | Should -Be '🤖⏸ Thanks — 1 answer(s) recorded. Still needed:'
        (Get-FakeIssue 75).Body | Should -Match 'Greet by first name or full name\? → Greet by first name\.'
        Assert-JourneyClean
    }

    It 'leaves the pause and the label as they are when a refine starts while the pause is not due yet' {
        # A refine run (an issue event or a stage=refine dispatch) on a paused issue: agent:paused
        # starts no run, so the conductor stops at its door. The pause resumes when it is due.
        $future = @{ paused_until = (Get-Date).ToUniversalTime().AddHours(1).ToString('o') }
        Add-FakeIssue -Number 76 -Title 'Greet the visitor by name' -Body (New-PlannedIssueBody -Number 76 -Unplanned -State $future) -Labels @('agent:paused')
        $body = (Get-FakeIssue 76).Body

        $started = Invoke-Orchestration -IssueNumber 76 -From refine

        $started | Should -BeFalse
        Get-FakePipelineLabel 76 | Should -Be 'agent:paused' -Because (Get-JourneyStory 76)
        (Get-FakeIssue 76).Body | Should -Be $body
        Get-FakeComments 76 | Should -BeNullOrEmpty
        Get-FakeTransitions | Should -BeNullOrEmpty
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'retries a failed issue on the owner''s comment' {
        Add-FakeIssue -Number 49 -Title 'Greet the visitor by name' -Body (New-PlannedIssueBody -Number 49) -Labels @('agent:failed')
        Add-FakeComment -Issue 49 -Body 'I fixed the fixture by hand — try again.'
        Add-FakeIssue -Number 60 -Title 'Greet the visitor by title' -Body (New-PlannedIssueBody -Number 60 -Unplanned) -Labels @('agent:failed')
        Add-FakeComment -Issue 60 -Body 'The question is settled in the body now — try again.'

        $null = Invoke-Orchestration -IssueNumber 49 -From comment
        $null = Invoke-Orchestration -IssueNumber 60 -From comment

        # Planned: implement starts again, with a fresh round of attempts.
        Get-FakePipelineLabel 49 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 49)
        @(Get-FakeCommentHeadings 49) | Should -Be @('· restarting from implement (owner comment)')
        # Not planned: refine runs again.
        Get-FakePipelineLabel 60 | Should -BeNullOrEmpty -Because (Get-JourneyStory 60)
        @(Get-FakeCommentHeadings 60) | Should -Be @('· restarting refine (owner comment)')
        $dispatch = @(Get-FakeDispatches)
        $dispatch.Count | Should -Be 1
        $dispatch[0].Stage | Should -Be 'refine'
        $dispatch[0].Issue | Should -Be 60
        @(Get-FakeEngineCalls | Where-Object Task -ne 'EngineCheck') | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'only notes a comment while the agent holds the issue' {
        Add-FakeIssue -Number 61 -Title 'Name the warden' -Body (New-PlannedIssueBody -Number 61) -Labels @('agent:implementing')
        Add-FakeComment -Issue 61 -Body 'How is this going?'

        $null = Invoke-Orchestration -IssueNumber 61 -From comment

        Get-FakePipelineLabel 61 | Should -Be 'agent:implementing' -Because (Get-JourneyStory 61)
        @(Get-FakeCommentHeadings 61) | Should -Be @('· comment noted')
        Get-FakeTransitions | Should -BeNullOrEmpty
        Get-FakeDispatches | Should -BeNullOrEmpty
        @(Get-FakeEngineCalls | Where-Object Task -ne 'EngineCheck') | Should -BeNullOrEmpty
        Assert-JourneyClean
    }
}
