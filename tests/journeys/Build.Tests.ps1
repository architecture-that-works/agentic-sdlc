#Requires -Version 7.0
<#
    Build journeys — a queued issue (agent:backlog) through implement, review and ship.
    Enters only through Invoke-Orchestration -From implement and asserts what the owner
    sees: the label, the comments, the pull request, and what was pushed to the remote.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')

    $script:StartFiles = @{
        'README.md'  = "# Sandbox`n"
        'CONTEXT.md' = "# CONTEXT.md`n`n## Glossary`n`n| Term | Definition |`n|---|---|`n"
    }

    # One implement run: it reads the glossary, writes a row and runs a test.
    function Add-ImplementRun {
        param([string]$Row, [string]$Message)
        Add-EngineResult -Task ImplementSmall `
            -Edits @{ 'CONTEXT.md' = "$($script:StartFiles['CONTEXT.md'])$Row`n" } `
            -ToolCalls @(
                @{ Name = 'Read'; Input = @{ file_path = 'CONTEXT.md' } }
                @{ Name = 'Edit'; Input = @{ file_path = 'CONTEXT.md' } }
                @{ Name = 'Bash'; Input = @{ command = 'uv run pytest tests/app/test_main.py' } }
            ) `
            -Reply "- ``CONTEXT.md`` — glossary row added`n- Left undone: none`n- Issues discovered: none"
        Add-EngineResult -Task CommitMessage -Reply $Message
    }
}

Describe 'Build journey' {
    BeforeEach { $script:repo = Start-Journey -Name "Build: $($____Pester.CurrentTest.Name)" -Files $script:StartFiles }
    AfterEach { Stop-Journey $script:repo }

    It 'implements and reviews a change to a governance file, then holds it ready for the owner' {
        Add-FakeIssue -Number 12 -Title 'Name the journeys in the glossary' -Body (New-PlannedIssueBody -Number 12) -Labels @('agent:backlog')
        Add-ImplementRun -Row '| Journey | A test that follows an issue through the conductor |' -Message 'docs(#12): name the journeys in the glossary'
        Add-EngineResult -Task Review -Answer @{ verdict = 'approved'; report = 'Every acceptance criterion is met.' }

        Invoke-Orchestration -IssueNumber 12 -From implement

        Get-FakePipelineLabel 12 | Should -Be 'human:approval' -Because (Get-JourneyStory 12)
        $branch = 'feature/12-name-journeys-glossary'
        $pr = Get-FakePullRequest -Head $branch
        $pr.State   | Should -Be 'OPEN'
        $pr.IsDraft | Should -BeFalse
        $pr.Body    | Should -Match 'Closes #12'
        Get-RemoteBranches $repo | Should -Contain $branch
        Get-RemoteCommits $repo -Branch $branch | Should -Be @('docs(#12): name the journeys in the glossary')
        Get-RemoteFiles $repo -Branch $branch | Should -Be @('CONTEXT.md')

        $headings = Get-FakeCommentHeadings 12
        $headings | Should -Contain '🤖✅ Tests Passing'
        $headings | Should -Contain '🤖 Implementation'
        $headings | Should -Contain '🤖✅ Review Approved'
        $headings[-1] | Should -Be '🤖⏸ Held for human approval'
        $held = (Get-FakeComments 12)[-1].Body
        $held | Should -Match 'it changes governance files'
        $held | Should -Match '`CONTEXT.md` — \+1 -0'
        @($headings | Where-Object { $_ -like '🤖❌*' }) | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'starts a second attempt after a review rejection, which is approved and held' {
        Add-FakeIssue -Number 13 -Title 'Name the journeys in the glossary' -Body (New-PlannedIssueBody -Number 13) -Labels @('agent:backlog')
        Add-ImplementRun -Row '| Journey | A test |' -Message 'docs(#13): name the journeys in the glossary'
        Add-EngineResult -Task Review -Answer @{ verdict = 'rejected'; report = 'Fix 1. The definition does not say what a journey follows.' }
        Add-ImplementRun -Row '| Journey | A test that follows an issue through the conductor |' -Message 'docs(#13): say what a journey follows'
        Add-EngineResult -Task Review -Answer @{ verdict = 'approved'; report = 'Fix 1 is done; every criterion is met.' }

        Invoke-Orchestration -IssueNumber 13 -From implement

        Get-FakePipelineLabel 13 | Should -Be 'human:approval' -Because (Get-JourneyStory 13)
        $branch = 'feature/13-name-journeys-glossary'
        $pr = Get-FakePullRequest -Head $branch
        $pr.State   | Should -Be 'OPEN'
        $pr.IsDraft | Should -BeFalse
        @($global:FakeGitHub.PullRequests).Count | Should -Be 1
        Get-RemoteCommits $repo -Branch $branch | Should -Be @('docs(#13): say what a journey follows', 'docs(#13): name the journeys in the glossary')

        $headings = Get-FakeCommentHeadings 13
        $headings | Should -Contain '🤖❌ Review Rejected'
        $headings | Should -Contain '🤖🔁 Attempt 1/3 failed at **review** — Review rejected the implementation — the latest 🤖❌ Review Rejected comment lists what to fix.'
        $headings | Should -Contain '🤖✅ Review Approved'
        @($headings | Where-Object { $_ -eq '🤖 Implementation' }).Count | Should -Be 2
        $headings[-1] | Should -Be '🤖⏸ Held for human approval'
        # The second attempt saw the rejection: it is in the signal history of its prompt.
        (Get-FakeEngineCalls -Task ImplementSmall)[1].Prompt | Should -Match 'Fix 1\. The definition does not say what a journey follows\.'
        Assert-JourneyClean
    }
}
