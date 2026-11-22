#Requires -Version 7.0
<#
    Decision table — what an owner's comment leads to, by the pipeline state the issue
    is in. One row per state; each row enters through Invoke-Orchestration -From comment
    and asserts what the owner sees: the comment the pipeline answers with, whether the
    label stays, and that no model was called. Then the states whose comment starts
    something: a retry of a failed issue, and a revision of a held pull request.

    The table asserts outcomes, never the OnComment values of $PipelineStates
    (lib/Config.ps1): those are written once, there (CONTEXT.md, "One definition").
    A comment that starts refine (human:decision, an unlabelled issue) is the Refine
    journey's.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
}

Describe 'Decision: an owner comment' {
    BeforeEach { $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" }
    AfterEach { Stop-Journey $script:repo }

    It 'on <Label> is answered with <Answer>' -ForEach @(
        @{ Label = 'agent:backlog';      Answer = '· comment noted' }
        @{ Label = 'agent:implementing'; Answer = '· comment noted' }
        @{ Label = 'agent:reviewing';    Answer = '· comment noted' }
        @{ Label = 'agent:shipped';      Answer = 'nothing' }
        @{ Label = 'human:approval';     Answer = '· no open PR found for this issue — comment noted, but no revision started' }
    ) {
        Add-FakeIssue -Number 30 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 30) -Labels @($Label)
        Add-FakeComment -Issue 30 -Body 'How is this going?'

        $null = Invoke-Orchestration -IssueNumber 30 -From comment

        $expected = if ($Answer -eq 'nothing') { @() } else { @($Answer) }
        @(Get-FakeCommentHeadings 30 | Where-Object { $_ -ne 'How is this going?' }) | Should -Be $expected -Because (Get-JourneyStory 30)
        Get-FakePipelineLabel 30 | Should -Be $Label
        # Every run pings the engine first (EngineCheck); no stage's model runs.
        @(Get-FakeEngineCalls | Where-Object Task -ne 'EngineCheck') | Should -BeNullOrEmpty
        Get-FakeTransitions | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'on agent:failed restarts a planned issue at implement' {
        Add-FakeIssue -Number 31 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 31) -Labels @('agent:failed')
        Add-FakeComment -Issue 31 -Body 'I fixed the token; try again.'

        $stage = Invoke-Orchestration -IssueNumber 31 -From comment

        $stage | Should -Be 'implement'
        Get-FakePipelineLabel 31 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 31)
        @(Get-FakeCommentHeadings 31)[-1] | Should -Be '· restarting from implement (owner comment)'
        @(Get-FakeEngineCalls | Where-Object Task -ne 'EngineCheck') | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'on agent:failed sends an issue that is not planned back to refine' {
        Add-FakeIssue -Number 32 -Title 'Greet the visitor by name' -Body (New-IssueBody) -Labels @('agent:failed')
        Add-FakeComment -Issue 32 -Body 'The goal is clearer now.'

        $stage = Invoke-Orchestration -IssueNumber 32 -From comment

        $stage | Should -Be 'refine'
        Get-FakePipelineLabel 32 | Should -BeNullOrEmpty
        @($global:FakeGitHub.Dispatches | ForEach-Object { "$($_.Workflow) $($_.Fields -join ' ')" }) | Should -Be @('afk.yml stage=refine issue_number=32')
        Assert-JourneyClean
    }

    It 'on human:approval with an open pull request dispatches a revision' {
        Stop-Journey $script:repo
        $script:repo = Start-Journey -Name 'Decision: a revision of a held pull request' -Files (Get-JourneyFiles)
        $null = New-HeldIssue -Number 33 -Title 'Name the decisions' -Row '| Decision | A table of outcomes |'
        Add-FakeComment -Issue 33 -Body 'Call it a decision table.'

        $null = Invoke-Orchestration -IssueNumber 33 -From comment

        Get-FakePipelineLabel 33 | Should -Be 'agent:implementing' -Because (Get-JourneyStory 33)
        @(Get-FakeCommentHeadings 33)[-1] | Should -Be "· revision dispatched — implement pipeline will pick up the owner's change request"
        @($global:FakeGitHub.Dispatches | ForEach-Object { "$($_.Workflow) $($_.Fields -join ' ')" }) | Should -Be @('afk.yml stage=implement issue_number=33')
        Assert-JourneyClean
    }
}
