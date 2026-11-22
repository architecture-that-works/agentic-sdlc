#Requires -Version 7.0
<#
    Conflict journeys — a held pull request whose branch conflicts with the default
    branch once another pull request merged. Enters as the workflow does: after the
    merge, Start-ConflictRounds (the conflict-rounds job, on a full fetch); then the
    round it dispatched, Invoke-Orchestration -From implement. Asserts what the owner
    sees: the label, the comments, the pull request and what reached the remote.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')

    $script:RowA = '| Journey | A test that follows an issue through the conductor |'
    $script:RowB = '| Fake | The one stand-in for a seam the journeys run on |'

    # Two issues held for the owner, both adding a glossary row at the same place. The
    # owner merges the first; the second's branch now conflicts with main.
    function Start-HeldConflict {
        $script:prA = New-HeldIssue -Number 40 -Title 'Name the journeys in the glossary' -Row $script:RowA
        $script:prB = New-HeldIssue -Number 41 -Title 'Name the fakes in the glossary' -Row $script:RowB
        $merged = Complete-FakePullRequest -Number $script:prA.Number -Merged
        Complete-HeldPR @merged
        Sync-FakeRepo $script:repo
    }
}

Describe 'Conflict journey' {
    BeforeEach { $script:repo = Start-Journey -Name "Conflict: $($____Pester.CurrentTest.Name)" -Files (Get-JourneyFiles) }
    AfterEach { Stop-Journey $script:repo }

    It 'starts a round for the held pull request that conflicts after a merge, and leaves a clean one alone' {
        Add-FakeIssue -Number 42 -Title 'Say who reads the security policy' -Body (New-PlannedIssueBody -Number 42) -Labels @('agent:backlog')
        Add-ImplementRun -Edits @{ 'SECURITY.md' = "# Security`n`nThe owner reads every report.`n" } -Message 'docs(#42): say who reads the security policy'
        Add-ReviewVerdict
        Invoke-Orchestration -IssueNumber 42 -From implement
        Get-FakePipelineLabel 42 | Should -Be 'human:approval' -Because (Get-JourneyStory 42)
        $prC = @($global:FakeGitHub.PullRequests | Where-Object { $_.Head -like 'feature/42-*' })[0]
        Start-HeldConflict
        $cleanHeadings = Get-FakeCommentHeadings 42
        $heads = @(Get-RemoteBranches $repo | ForEach-Object { "$_ $(Get-RemoteHead $repo -Branch $_)" })

        $rows = @(Start-ConflictRounds -MergedPR $prA.Number)

        $rows | Sort-Object IssueNumber | ForEach-Object { "#$($_.IssueNumber) PR #$($_.PRNumber) conflicts=$($_.Conflicts) round=$($_.RoundStarted)" } |
            Should -Be @("#41 PR #$($prB.Number) conflicts=True round=True", "#42 PR #$($prC.Number) conflicts=False round=False")

        Get-FakePipelineLabel 41 | Should -Be 'agent:implementing' -Because (Get-JourneyStory 41)
        (Get-FakeCommentHeadings 41)[-1] | Should -Be "🤖⚠️ Merge conflict after PR #$($prA.Number) merged — a round is starting"
        @($global:FakeGitHub.Dispatches | Where-Object { $_.Fields -contains 'issue_number=41' -and $_.Fields -contains 'stage=implement' }).Count | Should -Be 1

        Get-FakePipelineLabel 42 | Should -Be 'human:approval'
        Get-FakeCommentHeadings 42 | Should -Be $cleanHeadings
        @($global:FakeGitHub.Dispatches | Where-Object { $_.Fields -contains 'issue_number=42' }) | Should -BeNullOrEmpty
        $prC.IsDraft | Should -BeFalse

        # The merged issue shipped, and the check skips its PR.
        Get-FakePipelineLabel 40 | Should -Be 'agent:shipped'
        @($rows | Where-Object { $_.IssueNumber -eq 40 }) | Should -BeNullOrEmpty
        # The probe changed no branch on the remote.
        @(Get-RemoteBranches $repo | ForEach-Object { "$_ $(Get-RemoteHead $repo -Branch $_)" }) | Should -Be $heads

        # The check runs again (another merge) while the round waits: it starts nothing more.
        $again = @(Start-ConflictRounds -MergedPR $prA.Number)
        @($again | Where-Object { $_.IssueNumber -eq 41 }) | Should -BeNullOrEmpty
        @($global:FakeGitHub.Dispatches | Where-Object { $_.Fields -contains 'issue_number=41' }).Count | Should -Be 1
        @(Get-FakeCommentHeadings 41 | Where-Object { $_ -like '🤖⚠️ Merge conflict after*' }).Count | Should -Be 1
        Assert-JourneyClean
    }

    It 'has the agent settle a conflict with the default branch, then holds the pull request again' {
        Start-HeldConflict
        $null = Start-ConflictRounds -MergedPR $prA.Number
        $settled = Get-GlossaryText -Rows $RowA, $RowB
        Add-ImplementRun -Edits @{ 'CONTEXT.md' = $settled }
        Add-ReviewVerdict

        Invoke-Orchestration -IssueNumber 41 -From implement

        Get-FakePipelineLabel 41 | Should -Be 'human:approval' -Because (Get-JourneyStory 41)
        $headings = Get-FakeCommentHeadings 41
        $headings | Should -Contain '🤖⚠️ Merge conflict with main — the agent resolves it first'
        (Get-FakeComments 41 | Where-Object { $_.Body.StartsWith('🤖⚠️ Merge conflict with main') }).Body | Should -Match '- `CONTEXT.md`'
        $headings[-1] | Should -Be '🤖⏸ Held for human approval'
        @($headings | Where-Object { $_ -like '🤖❌*' }) | Should -BeNullOrEmpty
        # Settling the conflict was the agent's first task.
        $prompt = (Get-FakeEngineCalls -Task ImplementSmall)[-1].Prompt
        $prompt | Should -Match 'MERGE CONFLICT:'
        $prompt | Should -Match '(?m)^- CONTEXT\.md$'
        $prompt.IndexOf('MERGE CONFLICT:') | Should -BeLessThan $prompt.IndexOf('INSTRUCTIONS:')
        # The branch now holds main and both rows, and still changes only the glossary.
        Get-RemoteFileContent $repo -Branch $prB.Head -Path 'CONTEXT.md' | Should -Be $settled.TrimEnd("`n")
        Get-RemoteCommits $repo -Branch $prB.Head | Should -Contain "chore(#41): merge main into $($prB.Head)"
        Get-RemoteFiles $repo -Branch $prB.Head | Should -Be @('CONTEXT.md')
        # One pull request for the issue: back to draft for the round, ready again when held.
        @($global:FakeGitHub.PullRequests | Where-Object { $_.Head -eq $prB.Head }).Count | Should -Be 1
        $timeline = Get-FakePrTimeline $prB.Number
        $timeline[-1] | Should -Be 'marked ready'
        $timeline | Should -Contain 'back to draft'
        $prB.IsDraft | Should -BeFalse
        Assert-JourneyClean
    }

    It 'ends the round and names the files when the agent leaves conflict markers' {
        Start-HeldConflict
        $null = Start-ConflictRounds -MergedPR $prA.Number
        $before = Get-RemoteHead $repo -Branch $prB.Head
        # The agent's turn ends with the markers git wrote still in the file.
        Add-EngineResult -Task ImplementSmall -Reply "- Left undone: the conflict in CONTEXT.md`n- Issues discovered: none"

        Invoke-Orchestration -IssueNumber 41 -From implement

        Get-FakePipelineLabel 41 | Should -Be 'agent:failed' -Because (Get-JourneyStory 41)
        $headings = Get-FakeCommentHeadings 41
        $headings | Should -Contain '🤖⚠️ Merge conflict with main — the agent resolves it first'
        $headings[-1] | Should -Be '🤖❌ Conflict markers left — needs you'
        (Get-FakeComments 41)[-1].Body | Should -Match '(?m)^- `CONTEXT\.md`$'
        @($headings | Where-Object { $_ -like '🤖🔁*' -or $_ -like '🤖❌ Implement Failed*' }) | Should -BeNullOrEmpty
        # One attempt, no review, and nothing pushed.
        @(Get-FakeEngineCalls -Task ImplementSmall).Count | Should -Be 3   # two held issues, then this round
        @(Get-FakeEngineCalls -Task Review).Count | Should -Be 2
        Get-RemoteHead $repo -Branch $prB.Head | Should -Be $before
        Assert-JourneyClean
    }

    It 'fails the attempt when the default branch moves during the round, and the next attempt settles the conflict' {
        Add-FakeIssue -Number 43 -Title 'Name the journeys in the glossary' -Body (New-PlannedIssueBody -Number 43) -Labels @('agent:backlog')
        Add-ImplementRun -Edits @{ 'CONTEXT.md' = (Get-GlossaryText -Rows $RowA) } -Message 'docs(#43): name the journeys in the glossary'
        # While the review runs, another change to the same lines reaches main.
        Add-ReviewVerdict -During { $null = Push-RemoteCommit $script:repo -Files @{ 'CONTEXT.md' = (Get-GlossaryText -Rows $script:RowB) } -Message 'docs: name the fakes' }
        $settled = Get-GlossaryText -Rows $RowA, $RowB
        Add-ImplementRun -Edits @{ 'CONTEXT.md' = $settled }
        Add-ReviewVerdict

        Invoke-Orchestration -IssueNumber 43 -From implement

        Get-FakePipelineLabel 43 | Should -Be 'human:approval' -Because (Get-JourneyStory 43)
        $headings = Get-FakeCommentHeadings 43
        $headings | Should -Contain '🤖❌ Merge Conflict'
        (Get-FakeComments 43 | Where-Object { $_.Body.StartsWith('🤖❌ Merge Conflict') }).Body | Should -Match '- `CONTEXT.md`'
        $max = Get-OrchestratorSetting -Name MaxRetries
        $headings | Should -Contain "🤖🔁 Attempt 1/$max failed at **ship** — Merge conflict between feature/43-name-journeys-glossary and main in: CONTEXT.md"
        $headings | Should -Contain '🤖⚠️ Merge conflict with main — the agent resolves it first'
        $headings[-1] | Should -Be '🤖⏸ Held for human approval'
        $pr = @($global:FakeGitHub.PullRequests)[0]
        @($global:FakeGitHub.PullRequests).Count | Should -Be 1
        Get-RemoteFileContent $repo -Branch $pr.Head -Path 'CONTEXT.md' | Should -Be $settled.TrimEnd("`n")
        Assert-JourneyClean
    }
}
