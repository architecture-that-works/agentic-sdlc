#Requires -Version 7.0
<#
    Refine journeys — an issue the owner opened, from its first run to agent:backlog.
    Enters only through Invoke-Orchestration (-From refine | comment) and asserts what
    the owner sees: the label, the comments, the sections of the issue body.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')
}

Describe 'Refine journey' {
    BeforeEach { $script:repo = Start-Journey -Name "Refine: $($____Pester.CurrentTest.Name)" }
    AfterEach { Stop-Journey $script:repo }

    It 'refines, plans and queues an issue with nothing open' {
        Add-FakeIssue -Number 7 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        Add-EngineResult -Task Refine -Reply (New-GrillReply)
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 7 -From refine

        Get-FakePipelineLabel 7 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 7)
        $body = (Get-FakeIssue 7).Body
        $body | Should -Match '## Agent Brief'
        $body | Should -Match '## Architecture Impact'
        $body | Should -Match '## Implementation Plan'
        $headings = Get-FakeCommentHeadings 7
        $headings | Should -Contain '· refined — open_questions=0'
        $headings | Should -Contain '· architected — blast-radius impact written to issue body'
        $headings | Should -Contain '· planned — implementation plan written to issue body'
        $headings[-1] | Should -BeLike '🤖✅ Ready — refined, architected and planned*'
        @($headings | Where-Object { $_ -like '🤖❌*' -or $_ -like '🤖⚠️*' }) | Should -BeNullOrEmpty
        Get-RemoteBranches $repo | Should -Be @('main')
        Assert-JourneyClean
    }

    It 'asks the owner, records the answer from a comment, and queues the issue' {
        Add-FakeIssue -Number 8 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        $question = [ordered]@{
            text = 'Greet by first name or full name?'; raised_by = 'self-grill-subagent'
            decision = 'First name — because it reads friendlier'
            alternatives = @('Full name — formal', 'Whatever the visitor typed — no parsing')
        }
        Add-EngineResult -Task Refine -Reply (New-GrillReply -Open @($question))
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 8 -From refine

        Get-FakePipelineLabel 8 | Should -Be 'human:decision' -Because (Get-JourneyStory 8)
        (Get-FakeCommentHeadings 8)[-1] | Should -Be '🤖⏸ Needs your decision — 1 question(s) before this can be built:'
        (Get-FakeIssue 8).Body | Should -Match '### Waiting on you'

        # The owner answers in a plain comment; the comment entry point takes it from there.
        Add-FakeComment -Issue 8 -Body 'ok'
        Add-EngineResult -Task Refine -Reply '{"answers":[{"id":1,"status":"answered","decision":"Greet by first name."}],"new_questions":[]}'
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 8 -From comment

        Get-FakePipelineLabel 8 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 8)
        $body = (Get-FakeIssue 8).Body
        $body | Should -Match '### Decided'
        $body | Should -Match 'Greet by first name or full name\? → Greet by first name\.'
        $body | Should -Not -Match '### Waiting on you'
        (Get-FakeCommentHeadings 8)[-1] | Should -BeLike '🤖✅ Ready — refined, architected and planned*'
        Assert-JourneyClean
    }

    It 'starts nothing for an issue whose author is not trusted' {
        Add-FakeIssue -Number 9 -Title 'Please add my feature' -Body (New-IssueBody) -AuthorAssociation 'NONE'

        $null = Invoke-Orchestration -IssueNumber 9 -From refine

        Get-FakePipelineLabel 9 | Should -BeNullOrEmpty
        Get-FakeComments 9 | Should -BeNullOrEmpty
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Get-FakeTransitions | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'answers an owner comment on an untrusted issue with a noise line, and starts nothing' {
        Add-FakeIssue -Number 10 -Title 'Please add my feature' -Body (New-IssueBody) -AuthorAssociation 'CONTRIBUTOR'
        Add-FakeComment -Issue 10 -Body 'Looks useful — can the pipeline take this?'

        $null = Invoke-Orchestration -IssueNumber 10 -From comment

        Get-FakePipelineLabel 10 | Should -BeNullOrEmpty
        (Get-FakeCommentHeadings 10) | Should -Be @('· not processed — opened by an outside contributor; open your own issue to adopt it')
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Assert-JourneyClean
    }
}
