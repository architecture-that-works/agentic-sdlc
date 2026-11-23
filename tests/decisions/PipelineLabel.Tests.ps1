#Requires -Version 7.0
<#
    Decision table — where an issue goes from each pipeline label: when it is re-entered
    (Restart-Issue: retry.ps1, an owner's comment on agent:failed, the warden), and what
    the hourly warden does with an issue that has gone quiet at it (Invoke-Reconciliation).
    One row per label; each row enters through the exported function the real run calls
    and asserts what the owner sees: the label afterwards (always exactly one —
    Get-FakePipelineLabel throws on two), the comment, the workflow dispatched.

    The rows assert outcomes, never the AllowedFrom, Holder or Recovery values of
    $PipelineStates (lib/Config.ps1): the table is written once, there. Every label
    change a row causes is checked against it by StateMachine.Tests.ps1.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
}

Describe 'Decision: re-entering an issue' {
    BeforeEach { $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" }
    AfterEach { Stop-Journey $script:repo }

    It 'a planned issue at <From> re-enters at implement, on agent:backlog' -ForEach @(
        @{ From = $null }
        @{ From = 'agent:refining' }
        @{ From = 'agent:implementing' }
        @{ From = 'agent:reviewing' }
        @{ From = 'agent:paused' }
        @{ From = 'agent:failed' }
        @{ From = 'human:decision' }
        @{ From = 'human:approval' }
    ) {
        Add-FakeIssue -Number 40 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 40) -Labels @($From | Where-Object { $_ })

        $stage = Restart-Issue -IssueNumber 40 -Reason 'retry requested'

        $stage | Should -Be 'implement'
        Get-FakePipelineLabel 40 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 40)
        @(Get-FakeCommentHeadings 40)[-1] | Should -Be '· restarting from implement (retry requested)'
        Assert-JourneyClean
    }

    It 'keeps the owner''s merge hold in the carrier when a later state replaces human:approval' {
        Add-FakeIssue -Number 41 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 41) -Labels @('human:approval')

        $null = Restart-Issue -IssueNumber 41

        Get-FakePipelineLabel 41 | Should -Be 'agent:backlog'
        (Get-FakeIssue 41).Body | Should -Match '"approval_required":\s*true'
        Assert-JourneyClean
    }

    It 'sends an issue that is not planned yet back to refine, without a pipeline label' {
        Add-FakeIssue -Number 42 -Title 'Greet the visitor by name' -Body (New-IssueBody) -Labels @('agent:implementing', 'enhancement')

        $stage = Restart-Issue -IssueNumber 42 -Reason 'retry requested'

        $stage | Should -Be 'refine'
        Get-FakePipelineLabel 42 | Should -BeNullOrEmpty
        @((Get-FakeIssue 42).Labels) | Should -Be @('enhancement')
        @($global:FakeGitHub.Dispatches | ForEach-Object { "$($_.Workflow) $($_.Fields -join ' ')" }) | Should -Be @('afk.yml stage=refine issue_number=42')
        @(Get-FakeCommentHeadings 42)[-1] | Should -Be '· restarting refine (retry requested)'
        Assert-JourneyClean
    }

    # agent:backlog is already the go signal: setting it again would start nothing, so
    # its implement run is dispatched, as the warden does.
    It 'gives a planned issue at agent:backlog its implement run again, and leaves its label' {
        Add-FakeIssue -Number 43 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 43) -Labels @('agent:backlog')

        $stage = Restart-Issue -IssueNumber 43 -Reason 'retry requested'

        $stage | Should -Be 'implement'
        Get-FakePipelineLabel 43 | Should -Be 'agent:backlog'
        @($global:FakeGitHub.Dispatches | ForEach-Object { "$($_.Workflow) $($_.Fields -join ' ')" }) | Should -Be @('afk.yml stage=implement issue_number=43')
        @(Get-FakeCommentHeadings 43)[-1] | Should -Be '· re-dispatching implement (retry requested)'
        Get-FakeTransitions | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    # agent:shipped is terminal: it is never re-entered.
    It 'refuses to re-enter an issue at agent:shipped and leaves its label' {
        Add-FakeIssue -Number 43 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 43) -Labels @('agent:shipped')

        { Restart-Issue -IssueNumber 43 } | Should -Throw "*transition from 'agent:shipped' to 'agent:backlog' is not allowed*"

        Get-FakePipelineLabel 43 | Should -Be 'agent:shipped'
        Get-FakeTransitions | Should -BeNullOrEmpty
    }

    It 'moves the issue to the lane of its new label on the board it states' {
        Set-JourneyBoard
        Add-FakeIssue -Number 44 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 44) -Labels @('human:approval')
        Add-FakeBoardItem -Issue 44 -Status 'Review'

        $null = Restart-Issue -IssueNumber 44

        (Get-FakeBoardItem 44).status | Should -Be 'Backlog'
        Assert-JourneyClean
    }
}

Describe 'Decision: the hourly warden' {
    BeforeEach {
        $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)"
        $script:stale = (Get-OrchestratorSetting -Name StuckAfterMinutes) + 30
    }
    AfterEach { Stop-Journey $script:repo }

    It 'an issue quiet at <Label> is <Outcome>' -ForEach @(
        @{ Label = $null;                Outcome = 're-entered at implement' }
        @{ Label = 'agent:refining';     Outcome = 're-entered at implement' }
        @{ Label = 'agent:backlog';      Outcome = 'given its implement run again' }
        @{ Label = 'agent:implementing'; Outcome = 're-entered at implement' }
        @{ Label = 'agent:reviewing';    Outcome = 're-entered at implement' }
        @{ Label = 'agent:paused';       Outcome = 'resumed at implement' }
        @{ Label = 'agent:shipped';      Outcome = 'left alone' }
        @{ Label = 'agent:failed';       Outcome = 'left alone' }
        @{ Label = 'human:decision';     Outcome = 'left alone' }
        @{ Label = 'human:approval';     Outcome = 'left alone' }
    ) {
        Add-FakeIssue -Number 45 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 45) `
            -Labels @($Label | Where-Object { $_ }) -IdleMinutes $script:stale

        $null = Invoke-Reconciliation

        $dispatched = @($global:FakeGitHub.Dispatches | ForEach-Object { "$($_.Workflow) $($_.Fields -join ' ')" })
        $headings   = @(Get-FakeCommentHeadings 45)
        switch ($Outcome) {
            'left alone' {
                Get-FakePipelineLabel 45 | Should -Be $Label
                $headings | Should -BeNullOrEmpty
                $dispatched | Should -BeNullOrEmpty
            }
            'given its implement run again' {
                Get-FakePipelineLabel 45 | Should -Be 'agent:backlog'
                $dispatched | Should -Be @('afk.yml stage=implement issue_number=45')
                $headings[-1] | Should -BeLike '· re-dispatching implement (no activity for * min at agent:backlog)'
            }
            'resumed at implement' {
                Get-FakePipelineLabel 45 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 45)
                $headings[-1] | Should -Be '· restarting from implement (usage limit lifted)'
            }
            default {
                Get-FakePipelineLabel 45 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 45)
                $headings[-1] | Should -BeLike '· restarting from implement (no activity for * min at *)'
            }
        }
        Assert-JourneyClean
    }

    It 'leaves an issue touched inside the grace period to the run that is on it' {
        Add-FakeIssue -Number 46 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 46) -Labels @('agent:implementing') -IdleMinutes 5

        $null = Invoke-Reconciliation

        Get-FakePipelineLabel 46 | Should -Be 'agent:implementing'
        Get-FakeCommentHeadings 46 | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'defers an in-flight state while an AFK run is live' {
        Add-FakeIssue -Number 47 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 47) -Labels @('agent:reviewing') -IdleMinutes $script:stale
        $global:FakeGitHub.LiveRuns = 1

        $null = Invoke-Reconciliation

        Get-FakePipelineLabel 47 | Should -Be 'agent:reviewing'
        Get-FakeCommentHeadings 47 | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'hands an issue to the owner once re-entry at the same label stops working' {
        $max  = Get-OrchestratorSetting -Name MaxReconcile
        $body = (New-PlannedIssueBody -Number 48) -replace '"open_questions"', "`"reconcile_count`": $max, `"reconciled_from`": `"agent:implementing`", `"open_questions`""
        Add-FakeIssue -Number 48 -Title 'Name the decisions' -Body $body -Labels @('agent:implementing') -IdleMinutes $script:stale

        $null = Invoke-Reconciliation

        Get-FakePipelineLabel 48 | Should -Be 'agent:failed' -Because (Get-JourneyStory 48)
        @(Get-FakeCommentHeadings 48)[-1] | Should -Be '🤖❌ Stuck at **agent:implementing** and re-entry is not working — needs you'
        Assert-JourneyClean
    }
}
