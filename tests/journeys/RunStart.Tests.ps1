#Requires -Version 7.0
<#
    Run-start journeys — the conductor's door (#424). Whether a refine or an implement run
    may start is read from StartsRun in $PipelineStates, before the engine is asked, the
    lock is taken or a label is set. A run that may not start stops there and changes
    nothing; a refine run that finds agent:failed re-enters the issue once instead.

    Each journey enters through Invoke-Orchestration the way the real run enters it: an
    implement run with -From implement (the agent:backlog label event, a stage=implement
    dispatch, a run on a person's machine), a refine run with -From refine (an issue
    event, a stage=refine dispatch, the backfill).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')

    # What the owner can see of an issue, and what the run did: its label, body and
    # comments, the label transitions and dispatches, and the engine calls.
    function Get-IssueSnapshot {
        param([int]$Number)
        return [pscustomobject]@{
            Label       = Get-FakePipelineLabel $Number
            Body        = (Get-FakeIssue $Number).Body
            Comments    = @(Get-FakeComments $Number).Count
            Transitions = @(Get-FakeTransitions).Count
            Dispatches  = @(Get-FakeDispatches).Count
            EngineCalls = @(Get-FakeEngineCalls).Count
        }
    }

    # Asserts the run changed nothing on issue -Number since -Before, and called no model.
    function Assert-Unchanged {
        param([int]$Number, $Before, [int]$NewComments = 0)
        $after = Get-IssueSnapshot $Number
        $after.Label       | Should -Be $Before.Label -Because (Get-JourneyStory $Number)
        $after.Body        | Should -Be $Before.Body
        $after.Comments    | Should -Be ($Before.Comments + $NewComments)
        $after.Transitions | Should -Be $Before.Transitions
        $after.Dispatches  | Should -Be $Before.Dispatches
        $after.EngineCalls | Should -Be $Before.EngineCalls -Because 'a run that may not start calls no model, not even the readiness check'
        @(Get-FakeCommentHeadings $Number | Where-Object { $_ -like '🤖❌*' }) | Should -BeNullOrEmpty
    }
}

Describe 'Run-start journey' {
    BeforeEach { $script:repo = Start-Journey -Name "RunStart: $($____Pester.CurrentTest.Name)" -Files (Get-JourneyFiles) }
    AfterEach { Stop-Journey $script:repo }

    It 'stops an implement run on a shipped issue with the stopped line, and without an error' {
        $pr = Invoke-BuildRound -Number 80 -Edits @{ 'docs/decisions.md' = "# Decisions`n" }
        Get-FakePipelineLabel 80 | Should -Be 'agent:shipped' -Because (Get-JourneyStory 80)
        $before = Get-IssueSnapshot 80

        # A stage=implement dispatch by hand, or a run on a person's machine.
        $started = Invoke-Orchestration -IssueNumber 80 -From implement

        $started | Should -BeFalse
        Assert-Unchanged -Number 80 -Before $before -NewComments 1
        @(Get-FakeCommentHeadings 80)[-1] | Should -Be "🤖⏹ Stopped — issue already shipped (PR #$($pr.Number) merged); this round pushes nothing more and opens no pull request."
        Assert-JourneyClean
    }

    It 'starts no round for an implement run on an issue held for the owner''s merge' {
        $null = New-HeldIssue -Number 81 -Title 'Name the journeys in the glossary' -Row '| Journey | A test that follows an issue through the conductor |'
        $before = Get-IssueSnapshot 81

        $started = Invoke-Orchestration -IssueNumber 81 -From implement

        $started | Should -BeFalse
        Assert-Unchanged -Number 81 -Before $before
        Assert-JourneyClean
    }

    It 'starts no round for an implement run on an issue waiting on the owner''s decision' {
        $open = @([ordered]@{ id = 1; text = 'Greet by first name or full name?'; raised_by = 'self-grill-subagent'
                decision = 'First name — because it reads friendlier'; alternatives = @('Full name — formal') })
        Add-FakeIssue -Number 82 -Title 'Greet the visitor by name' -Body (New-PlannedIssueBody -Number 82 -Unplanned -State @{ open_questions = $open }) -Labels @('human:decision')
        $before = Get-IssueSnapshot 82

        $started = Invoke-Orchestration -IssueNumber 82 -From implement

        $started | Should -BeFalse
        Assert-Unchanged -Number 82 -Before $before
        Assert-JourneyClean
    }

    It 're-enters a failed issue once when a refine run finds it, with the failed run''s error notes' {
        $failed = @{ failed_at = 'plan'; failed_reason = 'Plan returned no paths to modify.' }
        Add-FakeIssue -Number 83 -Title 'Greet the visitor by name' -Body (New-PlannedIssueBody -Number 83 -Unplanned -State $failed) -Labels @('agent:failed')
        Add-FakeComment -Issue 83 -Body "🤖❌ Refine failed after 3 attempts at plan — needs you.`n``````text`nPlan returned no paths to modify.`n``````"

        # A stage=refine dispatch by hand on the failed issue.
        $null = Invoke-Orchestration -IssueNumber 83 -From refine

        # Re-entered through Restart-Issue: the label is cleared and refine is dispatched.
        Get-FakePipelineLabel 83 | Should -BeNullOrEmpty -Because (Get-JourneyStory 83)
        $dispatch = @(Get-FakeDispatches)
        $dispatch.Count | Should -Be 1
        $dispatch[0].Stage | Should -Be 'refine'
        $dispatch[0].Issue | Should -Be 83
        # Recorded as a re-entry from agent:failed, in the carrier and in a signal comment,
        # with the error notes the new refine reads in the issue body.
        $reentry = @((Get-CarrierState 83).transitions | Where-Object { $_.PSObject.Properties['reason'] -and $_.reason -eq 'refine from agent:failed' })
        $reentry.Count | Should -Be 1
        $reentry[0].notes | Should -Match 'Plan returned no paths to modify\.'
        $reentry[0].notes | Should -Match 'Refine failed after 3 attempts at plan'
        $headings = @(Get-FakeCommentHeadings 83)
        $headings[-2] | Should -BeLike '🤖🔁 Refine triggered from agent:failed*'
        $headings[-1] | Should -Be '· restarting refine (refine from agent:failed)'
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'hands a failed issue to the owner when it failed again after a re-entry from agent:failed' {
        $earlier = @(
            @{ from = $null; to = 'backlog'; runtime = 'laptop'; timestamp = '2026-11-01T10:00:00Z' }
            @{ from = 'backlog'; to = 'backlog'; reason = 'refine from agent:failed'; notes = 'Reason: Plan returned no paths to modify.'; runtime = 'github-actions'; timestamp = '2026-11-02T10:00:00Z' }
        )
        $failed = @{ failed_at = 'plan'; failed_reason = 'Plan returned no paths to modify, again.'; transitions = $earlier }
        Add-FakeIssue -Number 84 -Title 'Greet the visitor by name' -Body (New-PlannedIssueBody -Number 84 -Unplanned -State $failed) -Labels @('agent:failed')

        $null = Invoke-Orchestration -IssueNumber 84 -From refine

        Get-FakePipelineLabel 84 | Should -Be 'human:decision' -Because (Get-JourneyStory 84)
        $last = @(Get-FakeComments 84)[-1].Body
        ($last -split '\r?\n')[0] | Should -BeLike '🤖⏸ Needs your decision — this issue failed again after refine was already triggered from agent:failed*'
        $last | Should -Match 'Plan returned no paths to modify, again\.'
        Get-FakeDispatches | Should -BeNullOrEmpty
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Assert-JourneyClean
    }
}
