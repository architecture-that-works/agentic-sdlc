#Requires -Version 7.0
<#
    Build journeys — a queued issue (agent:backlog) through implement, review and ship.
    Enters through Invoke-Orchestration -From implement, as the workflow's implement job
    does, and asserts what the owner sees: the label, the comments, the pull request,
    and what was pushed to the remote.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')

    # A page under docs/: inside WritablePaths and outside GovernancePaths, so a
    # change to it alone is merged by the workflow without the owner.
    function Get-DocsEdit {
        param([string]$Line = 'A journey follows an issue through the conductor.')
        return @{ 'docs/journeys.md' = "# Journeys`n`n$Line`n" }
    }

    function Get-PullRequests { return @($global:FakeGitHub.PullRequests) }
}

Describe 'Build journey' {
    BeforeEach { $script:repo = Start-Journey -Name "Build: $($____Pester.CurrentTest.Name)" -Files (Get-JourneyFiles) }
    AfterEach { Stop-Journey $script:repo }

    It 'implements and reviews a change to a governance file, then holds it ready for the owner' {
        Add-FakeIssue -Number 12 -Title 'Name the journeys in the glossary' -Body (New-PlannedIssueBody -Number 12) -Labels @('agent:backlog')
        Add-ImplementRun -Edits @{ 'CONTEXT.md' = (Get-GlossaryText -Rows '| Journey | A test that follows an issue through the conductor |') } `
            -Message 'docs(#12): name the journeys in the glossary'
        Add-ReviewVerdict

        Invoke-Orchestration -IssueNumber 12 -From implement

        Get-FakePipelineLabel 12 | Should -Be 'human:approval' -Because (Get-JourneyStory 12)
        $branch = 'feature/12-name-journeys-glossary'
        $pr = Get-FakePullRequest -Head $branch
        $pr.State   | Should -Be 'OPEN'
        $pr.IsDraft | Should -BeFalse
        $pr.Body    | Should -Match 'Closes #12'
        # A draft while the round ran — reviewed as a draft — and ready once held.
        Get-FakePrTimeline $pr.Number | Should -Be @("opened as draft from $branch", 'review comment', 'marked ready')
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
        Add-ImplementRun -Edits @{ 'CONTEXT.md' = (Get-GlossaryText -Rows '| Journey | A test |') } -Message 'docs(#13): name the journeys in the glossary'
        Add-ReviewVerdict -Verdict rejected -Report 'Fix 1. The definition does not say what a journey follows.'
        Add-ImplementRun -Edits @{ 'CONTEXT.md' = (Get-GlossaryText -Rows '| Journey | A test that follows an issue through the conductor |') } `
            -Message 'docs(#13): say what a journey follows'
        Add-ReviewVerdict -Report 'Fix 1 is done; every criterion is met.'

        Invoke-Orchestration -IssueNumber 13 -From implement

        Get-FakePipelineLabel 13 | Should -Be 'human:approval' -Because (Get-JourneyStory 13)
        $branch = 'feature/13-name-journeys-glossary'
        $pr = Get-FakePullRequest -Head $branch
        $pr.State   | Should -Be 'OPEN'
        $pr.IsDraft | Should -BeFalse
        @(Get-PullRequests).Count | Should -Be 1
        Get-RemoteCommits $repo -Branch $branch | Should -Be @('docs(#13): say what a journey follows', 'docs(#13): name the journeys in the glossary')

        $headings = Get-FakeCommentHeadings 13
        $headings | Should -Contain '🤖❌ Review Rejected'
        $max = Get-OrchestratorSetting -Name MaxRetries
        $headings | Should -Contain "🤖🔁 Attempt 1/$max failed at **review** — Review rejected the implementation — the latest 🤖❌ Review Rejected comment lists what to fix."
        $headings | Should -Contain '🤖✅ Review Approved'
        @($headings | Where-Object { $_ -eq '🤖 Implementation' }).Count | Should -Be 2
        $headings[-1] | Should -Be '🤖⏸ Held for human approval'
        # The second attempt saw the rejection: it is in the signal history of its prompt.
        (Get-FakeEngineCalls -Task ImplementSmall)[1].Prompt | Should -Match 'Fix 1\. The definition does not say what a journey follows\.'
        Assert-JourneyClean
    }

    It 'implements, reviews and merges a change inside the writable paths once its required checks pass' {
        Add-FakeIssue -Number 20 -Title 'Describe the journeys in the docs' -Body (New-PlannedIssueBody -Number 20) -Labels @('agent:backlog')
        Add-ImplementRun -Edits (Get-DocsEdit) -Message 'docs(#20): describe the journeys'
        Add-ReviewVerdict
        # A skipped check passes, as the eval job skips when no file an eval reads changed.
        Set-FakeChecks -Conclusions @{ eval = 'skipped' }

        Invoke-Orchestration -IssueNumber 20 -From implement

        Get-FakePipelineLabel 20 | Should -Be 'agent:shipped' -Because (Get-JourneyStory 20)
        @(Get-PullRequests).Count | Should -Be 1
        $pr = (Get-PullRequests)[0]
        $pr.State | Should -Be 'MERGED'
        # A draft while the round ran, marked ready right before the workflow merged it.
        Get-FakePrTimeline $pr.Number | Should -Be @("opened as draft from $($pr.Head)", 'review comment', 'marked ready', 'squash-merged')
        Get-RemoteFileContent $repo -Branch main -Path 'docs/journeys.md' | Should -Be ((Get-DocsEdit)['docs/journeys.md'].TrimEnd("`n"))
        # Nothing was pushed after the merge: main is the remote's only branch, one squash commit ahead.
        Get-RemoteBranches $repo | Should -Be @('main')
        @(git --git-dir $repo.Remote log --format=%s refs/heads/main) | Should -Be @("$($pr.Title) (#$($pr.Number))", 'chore: start')

        $headings = Get-FakeCommentHeadings 20
        $headings | Should -Contain '🤖✅ Tests Passing'
        $headings | Should -Contain '🤖✅ Review Approved'
        $headings | Should -Not -Contain '🤖⏸ Held for human approval'
        $headings[-1] | Should -Be '🤖✅ Merged'
        (Get-FakeComments 20)[-1].Body | Should -Match "PR #$($pr.Number) squash-merged"
        Assert-JourneyClean
    }

    It 'gives the next attempt the failing verification run, and that attempt goes on' {
        Stop-Journey $script:repo
        $script:repo = Start-Journey -Name 'Build: verification fails, then passes' -Files (Get-JourneyFiles) -TestExit 1, 0
        Add-FakeIssue -Number 21 -Title 'Describe the journeys in the docs' -Body (New-PlannedIssueBody -Number 21) -Labels @('agent:backlog')
        Add-ImplementRun -Edits (Get-DocsEdit)
        Add-ImplementRun -Edits (Get-DocsEdit -Line 'A journey follows one issue.') -Message 'docs(#21): describe the journeys'
        Add-ReviewVerdict

        Invoke-Orchestration -IssueNumber 21 -From implement

        Get-FakePipelineLabel 21 | Should -Be 'agent:shipped' -Because (Get-JourneyStory 21)
        $headings = Get-FakeCommentHeadings 21
        $headings | Should -Contain '🤖⚠️ Tests Failing'
        $max = Get-OrchestratorSetting -Name MaxRetries
        $headings | Should -Contain "🤖🔁 Attempt 1/$max failed at **implement** — Test suite failed after implementation for issue #21"
        $headings.IndexOf('🤖⚠️ Tests Failing') | Should -BeLessThan $headings.IndexOf('🤖✅ Tests Passing')
        $headings[-1] | Should -Be '🤖✅ Merged'
        # The second attempt got the failure: the failing run's output is in its prompt.
        $second = (Get-FakeEngineCalls -Task ImplementSmall)[1].Prompt
        $second | Should -Match '🤖⚠️ Tests Failing'
        $second | Should -Match 'the greeting names nobody'
        @(Get-PullRequests).Count | Should -Be 1
        Assert-JourneyClean
    }

    It 'fails an attempt with the failed job''s log when a required check fails, and fails the issue when the attempts are used up' {
        $max = Get-OrchestratorSetting -Name MaxRetries
        Add-FakeIssue -Number 22 -Title 'Describe the journeys in the docs' -Body (New-PlannedIssueBody -Number 22) -Labels @('agent:backlog')
        Set-FakeChecks -Conclusions @{ test = 'failure' } -Logs @{ test = "collected 12 items`nFAILED tests/app/test_main.py::test_greeting - AssertionError: no name`n1 failed, 11 passed" }
        foreach ($n in 1..$max) {
            Add-ImplementRun -Edits (Get-DocsEdit -Line "Attempt ${n}: a journey follows an issue.") -Message "docs(#22): describe the journeys, take $n"
            Add-ReviewVerdict
        }

        Invoke-Orchestration -IssueNumber 22 -From implement

        Get-FakePipelineLabel 22 | Should -Be 'agent:failed' -Because (Get-JourneyStory 22)
        $failed = @(Get-FakeComments 22 | Where-Object { $_.Body.StartsWith('🤖❌ CI Failed') })
        $failed.Count | Should -Be $max
        foreach ($c in $failed) {
            $c.Body | Should -Match 'Failed checks: test — on commit [0-9a-f]{40}\.'
            $c.Body | Should -Match '\*\*test\*\* \(job \d+\) — last 3 log lines:'
            $c.Body | Should -Match 'FAILED tests/app/test_main.py::test_greeting - AssertionError: no name'
        }
        # Every attempt after the first got the failed job's log in its prompt.
        (Get-FakeEngineCalls -Task ImplementSmall)[1].Prompt | Should -Match 'AssertionError: no name'
        $headings = Get-FakeCommentHeadings 22
        $headings[-1] | Should -Be "🤖❌ Failed after $max attempts — needs you"
        $headings | Should -Not -Contain '🤖✅ Merged'
        $pr = (Get-PullRequests)[0]
        @(Get-PullRequests).Count | Should -Be 1
        $pr.State   | Should -Be 'OPEN'
        $pr.IsDraft | Should -BeTrue
        Get-RemoteFileContent $repo -Branch main -Path 'docs/journeys.md' | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'merges nothing when a required check is missing or has not passed at the ceiling' {
        Stop-Journey $script:repo
        $script:repo = Start-Journey -Name 'Build: checks missing at the ceiling' -Files (Get-JourneyFiles) -ChecksTimeoutSeconds 0
        $max = Get-OrchestratorSetting -Name MaxRetries
        Add-FakeIssue -Number 23 -Title 'Describe the journeys in the docs' -Body (New-PlannedIssueBody -Number 23) -Labels @('agent:backlog')
        Set-FakeChecks -Missing 'eval' -Conclusions @{ audit = $null; typecheck = 'neutral' }
        foreach ($n in 1..$max) {
            Add-ImplementRun -Edits (Get-DocsEdit -Line "Attempt $n.") -Message "docs(#23): describe the journeys, take $n"
            Add-ReviewVerdict
        }

        Invoke-Orchestration -IssueNumber 23 -From implement

        Get-FakePipelineLabel 23 | Should -Be 'agent:failed' -Because (Get-JourneyStory 23)
        $waited = @(Get-FakeComments 23 | Where-Object { $_.Body.StartsWith('🤖⚠️ CI did not pass within 0s') })
        $waited.Count | Should -Be $max
        foreach ($c in $waited) {
            $c.Body | Should -Match '- `eval \(not reported\)`'
            $c.Body | Should -Match '- `audit \(not passed\)`'
            $c.Body | Should -Match '- `typecheck \(not passed\)`'
            $c.Body | Should -Match 'Nothing was merged'
        }
        $headings = Get-FakeCommentHeadings 23
        $headings | Should -Not -Contain '🤖✅ Merged'
        $headings | Should -Not -Contain '🤖❌ CI Failed'
        $pr = (Get-PullRequests)[0]
        $pr.State | Should -Be 'OPEN'
        Get-FakePrTimeline $pr.Number | Should -Not -Contain 'squash-merged'
        Get-RemoteFileContent $repo -Branch main -Path 'docs/journeys.md' | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'holds a change outside the writable paths as a proposal, and flags a change to the agent''s own boundary' {
        Add-FakeIssue -Number 27 -Title 'Run the journeys in CI' -Body (New-PlannedIssueBody -Number 27) -Labels @('agent:backlog')
        Add-ImplementRun -Edits @{
            'Taskfile.yml'              = "version: '3'`n"
            '.github/workflows/ci.yml'  = "name: ci`n"
            'docs/journeys.md'          = "# Journeys`n"
        } -Message 'ci(#27): run the journeys in CI'
        Add-ReviewVerdict

        Invoke-Orchestration -IssueNumber 27 -From implement

        Get-FakePipelineLabel 27 | Should -Be 'human:approval' -Because (Get-JourneyStory 27)
        (Get-FakeCommentHeadings 27)[-1] | Should -Be '🤖⏸ Held for human approval'
        $held = (Get-FakeComments 27)[-1].Body
        $held | Should -Match 'it changes governance files and files outside the agent write allowlist'
        $held | Should -Match '(?m)^- `Taskfile\.yml` — \+1 -0$'
        $held | Should -Match ([regex]::Escape("- ``.github/workflows/ci.yml`` — +1 -0  ⚠️ **changes the agent's own boundary**"))
        $held | Should -Not -Match '`docs/journeys\.md`'
        $pr = (Get-PullRequests)[0]
        $pr.State   | Should -Be 'OPEN'
        $pr.IsDraft | Should -BeFalse
        Assert-JourneyClean
    }

    It 'ends the round at once and names the files when the engine refuses an edit' {
        Add-FakeIssue -Number 24 -Title 'Describe the journeys in the docs' -Body (New-PlannedIssueBody -Number 24) -Labels @('agent:backlog')
        Add-ImplementRun -Edits (Get-DocsEdit) -Message 'docs(#24): describe the journeys' `
            -RefusedEdits '.devcontainer/devcontainer.json', '.claude/settings.json'

        Invoke-Orchestration -IssueNumber 24 -From implement

        Get-FakePipelineLabel 24 | Should -Be 'agent:failed' -Because (Get-JourneyStory 24)
        @(Get-FakeEngineCalls -Task ImplementSmall).Count | Should -Be 1
        @(Get-FakeEngineCalls -Task Review).Count | Should -Be 0
        @(Get-PullRequests).Count | Should -Be 0
        $headings = Get-FakeCommentHeadings 24
        $headings[-1] | Should -Be '🤖❌ Engine refused an edit — needs you'
        $refusal = (Get-FakeComments 24)[-1].Body
        $refusal | Should -Match '- `\.devcontainer/devcontainer\.json` — the engine protects this path'
        $refusal | Should -Match '- `\.claude/settings\.json` — the engine protects this path'
        @($headings | Where-Object { $_ -like '🤖🔁*' -or $_ -like '🤖❌ Implement Failed*' }) | Should -BeNullOrEmpty
        # The rest of the attempt's work is on the branch for the owner, without a PR.
        $branch = @(Get-RemoteBranches $repo | Where-Object { $_ -like 'feature/24-*' })
        $branch.Count | Should -Be 1
        $refusal | Should -Match ([regex]::Escape("branch ``$($branch[0])``"))
        Get-RemoteFiles $repo -Branch $branch[0] | Should -Be @('docs/journeys.md')
        Assert-JourneyClean
    }

    It 'leaves a file on the secrets denylist out of the commit and reports it' {
        Stop-Journey $script:repo
        $files = Get-JourneyFiles
        $files['config/old_secret.txt'] = "retired`n"
        $script:repo = Start-Journey -Name 'Build: secrets denylist' -Files $files
        Add-FakeIssue -Number 25 -Title 'Name the journeys in the glossary' -Body (New-PlannedIssueBody -Number 25) -Labels @('agent:backlog')
        Add-ImplementRun -Edits @{
            'CONTEXT.md'                 = (Get-GlossaryText -Rows '| Journey | A test that follows an issue |')
            'docs/secrets-management.md' = "# Secrets`n`nEvery secret comes from the environment.`n"
            '.env'                       = "API_TOKEN=not-for-git`n"
            'config/deploy.key'          = "-----BEGIN KEY-----`n"
            'config/db_credentials.json' = "{ ""user"": ""app"" }`n"
            'config/secrets.json'        = "{ ""token"": ""x"" }`n"
            'certs/site.pem'             = "-----BEGIN CERTIFICATE-----`n"
            'certs/site.pfx'             = "binary`n"
            'config/old_secret.txt'      = $null   # a deletion is never held back
        } -Message 'docs(#25): name the journeys in the glossary'
        Add-ReviewVerdict

        Invoke-Orchestration -IssueNumber 25 -From implement

        Get-FakePipelineLabel 25 | Should -Be 'human:approval' -Because (Get-JourneyStory 25)
        $denied = @(Get-FakeComments 25 | Where-Object { $_.Body.StartsWith('🤖 Secrets Denylist') })
        $denied.Count | Should -Be 1
        $lines = @($denied[0].Body -split '\r?\n' | Where-Object { $_ -like 'Unstaged by the secrets denylist: *' })
        $lines | Sort-Object | Should -Be @(
            'Unstaged by the secrets denylist: .env'
            'Unstaged by the secrets denylist: certs/site.pem'
            'Unstaged by the secrets denylist: certs/site.pfx'
            'Unstaged by the secrets denylist: config/db_credentials.json'
            'Unstaged by the secrets denylist: config/deploy.key'
            'Unstaged by the secrets denylist: config/secrets.json'
        )
        $pr = (Get-PullRequests)[0]
        Get-RemoteFiles $repo -Branch $pr.Head | Sort-Object | Should -Be @('config/old_secret.txt', 'CONTEXT.md', 'docs/secrets-management.md')
        Get-RemoteFileContent $repo -Branch $pr.Head -Path 'config/old_secret.txt' | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'stops a round whose issue the owner shipped meanwhile, and never opens a second pull request' {
        Add-FakeIssue -Number 26 -Title 'Describe the journeys in the docs' -Body (New-PlannedIssueBody -Number 26) -Labels @('agent:backlog')
        # The first attempt opens the PR; its CI fails.
        Set-FakeChecks -Conclusions @{ lint = 'failure' }
        Add-ImplementRun -Edits (Get-DocsEdit) -Message 'docs(#26): describe the journeys'
        Add-ReviewVerdict
        # While the second attempt's agent runs, the owner merges the PR by hand, and the
        # workflow's pull_request-closed step reconciles the issue.
        Add-ImplementRun -Edits (Get-DocsEdit -Line 'Take two.') -Message 'docs(#26): describe the journeys again' -During {
            $closed = Complete-FakePullRequest -Number $global:FakeGitHub.PullRequests[0].Number -Merged -Ready
            Complete-HeldPR @closed
        }

        Invoke-Orchestration -IssueNumber 26 -From implement

        Get-FakePipelineLabel 26 | Should -Be 'agent:shipped' -Because (Get-JourneyStory 26)
        @(Get-PullRequests).Count | Should -Be 1
        $pr = (Get-PullRequests)[0]
        $pr.State | Should -Be 'MERGED'
        # Nothing was pushed after the merge: GitHub deleted the branch, and it stays gone.
        Get-RemoteBranches $repo | Should -Not -Contain $pr.Head
        Get-RemoteFileContent $repo -Branch main -Path 'docs/journeys.md' | Should -Be ((Get-DocsEdit)['docs/journeys.md'].TrimEnd("`n"))
        @(Get-FakeEngineCalls -Task Review).Count | Should -Be 1
        $headings = Get-FakeCommentHeadings 26
        $headings | Should -Contain '🤖✅ Merged'
        $headings[-1] | Should -Be "🤖⏹ Stopped — issue already shipped (PR #$($pr.Number) merged); this round pushes nothing more and opens no pull request."
        @($headings | Where-Object { $_ -like '🤖⏹*' }).Count | Should -Be 1
        @($headings | Where-Object { $_ -like '🤖❌ Failed*' -or $_ -like '🤖❌ Implement Failed*' }) | Should -BeNullOrEmpty
        Assert-JourneyClean
    }
}
