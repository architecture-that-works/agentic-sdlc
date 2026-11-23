#Requires -Version 7.0
<#
    Held journeys — a pull request held for the owner (human:approval), or left by a
    failed issue, and what the owner does with it. Enters as the workflow does: an owner comment through
    Invoke-Orchestration -From comment, then the implement round it dispatched
    (-From implement); a ship the owner runs by hand through Invoke-Ship and Resolve-PR,
    as the workflow's stage=ship job does; a merge or close of the PR through
    Complete-HeldPR, with the arguments the pull_request-closed step passes. Asserts
    what the owner sees.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')

    $script:Row = '| Journey | A test that follows an issue through the conductor |'
}

Describe 'Held journey' {
    BeforeEach { $script:repo = Start-Journey -Name "Held: $($____Pester.CurrentTest.Name)" -Files (Get-JourneyFiles) }
    AfterEach { Stop-Journey $script:repo }

    Context 'a pull request held for the owner' {
        BeforeEach { $script:pr = New-HeldIssue -Number 50 -Title 'Name the journeys in the glossary' -Row $script:Row }

        It 'starts a revision on the same pull request when the owner comments on a held issue' {
            Add-FakeComment -Issue 50 -Body 'Please also say that a journey asserts only what the owner sees.'

            $routed = Invoke-Orchestration -IssueNumber 50 -From comment

            $routed | Should -BeTrue
            Get-FakePipelineLabel 50 | Should -Be 'agent:implementing' -Because (Get-JourneyStory 50)
            @($global:FakeGitHub.Dispatches | Where-Object { $_.Fields -contains 'issue_number=50' -and $_.Fields -contains 'stage=implement' }).Count | Should -Be 1
            $pr.IsDraft | Should -BeFalse   # nothing changed the PR yet

            # The dispatched implement job.
            $revised = Get-GlossaryText -Rows "| Journey | A test that follows an issue through the conductor and asserts only what the owner sees |"
            Add-ImplementRun -Edits @{ 'CONTEXT.md' = $revised } -Message 'docs(#50): say what a journey asserts'
            Add-ReviewVerdict

            Invoke-Orchestration -IssueNumber 50 -From implement

            Get-FakePipelineLabel 50 | Should -Be 'human:approval' -Because (Get-JourneyStory 50)
            @($global:FakeGitHub.PullRequests).Count | Should -Be 1
            # A draft again while the round ran, ready again once held.
            $timeline = @(Get-FakePrTimeline $pr.Number)
            $round = $timeline[$timeline.IndexOf('back to draft')..($timeline.Count - 1)]
            $round | Should -Be @('back to draft', 'description rewritten', 'review comment', 'marked ready')
            $pr.State   | Should -Be 'OPEN'
            $pr.IsDraft | Should -BeFalse
            Get-RemoteCommits $repo -Branch $pr.Head | Should -Be @('docs(#50): say what a journey asserts', 'docs(#50): name the journeys in the glossary')
            # The revision read the owner's request.
            (Get-FakeEngineCalls -Task ImplementSmall)[-1].Prompt | Should -Match 'asserts only what the owner sees'
            $headings = Get-FakeCommentHeadings 50
            @($headings | Where-Object { $_ -eq '🤖⏸ Held for human approval' }).Count | Should -Be 2
            $headings[-1] | Should -Be '🤖⏸ Held for human approval'
            Assert-JourneyClean
        }

        It 'holds the pull request again when the owner runs ship by hand while a revision is queued' {
            Add-FakeComment -Issue 50 -Body 'Please also say that a journey asserts only what the owner sees.'
            $null = Invoke-Orchestration -IssueNumber 50 -From comment
            Get-FakePipelineLabel 50 | Should -Be 'agent:implementing' -Because (Get-JourneyStory 50)

            # The owner changes their mind and runs stage=ship, as the workflow's ship job does.
            $null = Invoke-Ship -IssueNumber 50 -PRNumber (Resolve-PR -IssueNumber 50)

            Get-FakePipelineLabel 50 | Should -Be 'human:approval' -Because (Get-JourneyStory 50)
            $headings = @(Get-FakeCommentHeadings 50)
            @($headings | Where-Object { $_ -eq '🤖⏸ Held for human approval' }).Count | Should -Be 2
            $pr.State   | Should -Be 'OPEN'
            $pr.IsDraft | Should -BeFalse
            Get-RemoteFileContent $repo -Branch main -Path 'CONTEXT.md' | Should -Be (Get-GlossaryText).TrimEnd("`n")
            Assert-JourneyClean
        }

        It 'fails the issue when the owner closes the held pull request without merging it' {
            $closed = Complete-FakePullRequest -Number $pr.Number

            Complete-HeldPR @closed

            Get-FakePipelineLabel 50 | Should -Be 'agent:failed' -Because (Get-JourneyStory 50)
            (Get-FakeCommentHeadings 50)[-1] | Should -Be "🤖⏸ PR #$($pr.Number) closed without merging"
            $pr.State | Should -Be 'CLOSED'
            Get-RemoteFileContent $repo -Branch main -Path 'CONTEXT.md' | Should -Be (Get-GlossaryText).TrimEnd("`n")
            Assert-JourneyClean
        }

        It 'ships the issue when the owner merges the held pull request' {
            $merged = Complete-FakePullRequest -Number $pr.Number -Merged

            Complete-HeldPR @merged

            Get-FakePipelineLabel 50 | Should -Be 'agent:shipped' -Because (Get-JourneyStory 50)
            $headings = Get-FakeCommentHeadings 50
            $headings[-1] | Should -Be '🤖✅ Merged'
            (Get-FakeComments 50)[-1].Body | Should -Match "PR #$($pr.Number) merged"
            $pr.State | Should -Be 'MERGED'
            Get-RemoteFileContent $repo -Branch main -Path 'CONTEXT.md' | Should -Be (Get-GlossaryText -Rows $Row).TrimEnd("`n")
            # The workflow's closed event for an issue that already shipped changes nothing.
            $count = @(Get-FakeComments 50).Count
            Complete-HeldPR @merged
            @(Get-FakeComments 50).Count | Should -Be $count
            Get-FakePipelineLabel 50 | Should -Be 'agent:shipped'
            Assert-JourneyClean
        }
    }

    It 'ships an issue the pipeline failed when the owner fixes its pull request by hand and merges it' {
        $max = Get-OrchestratorSetting -Name MaxRetries
        Add-FakeIssue -Number 51 -Title 'Describe the journeys in the docs' -Body (New-PlannedIssueBody -Number 51) -Labels @('agent:backlog')
        Set-FakeChecks -Conclusions @{ test = 'failure' }
        foreach ($n in 1..$max) {
            Add-ImplementRun -Edits @{ 'docs/journeys.md' = "# Journeys`n`nTake $n.`n" } -Message "docs(#51): describe the journeys, take $n"
            Add-ReviewVerdict
        }
        Invoke-Orchestration -IssueNumber 51 -From implement
        Get-FakePipelineLabel 51 | Should -Be 'agent:failed' -Because (Get-JourneyStory 51)
        $failed = @($global:FakeGitHub.PullRequests)[0]

        # The owner fixes the branch, marks the draft ready and merges it.
        $null = Push-RemoteCommit $repo -Branch $failed.Head -Files @{ 'docs/journeys.md' = "# Journeys`n`nFixed by hand.`n" } -Message 'docs(#51): fix by hand'
        $merged = Complete-FakePullRequest -Number $failed.Number -Merged -Ready
        Complete-HeldPR @merged

        Get-FakePipelineLabel 51 | Should -Be 'agent:shipped' -Because (Get-JourneyStory 51)
        (Get-FakeCommentHeadings 51)[-1] | Should -Be '🤖✅ Merged'
        Get-RemoteFileContent $repo -Branch main -Path 'docs/journeys.md' | Should -Be "# Journeys`n`nFixed by hand."
        Assert-JourneyClean
    }
}
