#Requires -Version 7.0
<#
    Decision table — what an owner's comment leads to, by the pipeline state the issue
    is in. One row per state; each row enters through Invoke-Orchestration -From comment
    and asserts what the owner sees: the comment the pipeline answers with, whether the
    label stays, and that no model was called.

    The table asserts outcomes, never the OnComment values of $PipelineStates
    (lib/Config.ps1): those are written once, there (CONTEXT.md, "One definition").
    The states whose comment starts a stage (refine, retry) are covered by the journeys.
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
}
