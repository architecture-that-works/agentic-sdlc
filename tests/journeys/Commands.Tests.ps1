#Requires -Version 7.0
<#
    Command journeys — the Commands a person runs by hand: sync (ISSUES.md blocks to
    issues on the board), setup (the board's ids to .env and the Actions variables, the
    base labels, the code owners) and protect (branch rules and merge settings, then
    their verification).

    Each Command runs in-process with the call operator against the fake GitHub, on the
    journey's temporary repository (-Root), and the journey asserts what the owner sees:
    the issues and the board, the files the Command wrote, the repository's settings,
    the lines it printed and its exit code. No Command reads this repository's own .env.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')
    $script:Tasks    = (Resolve-Path (Join-Path $PSScriptRoot '../../.github/tasks')).ProviderPath
    $script:Template = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.github/ISSUE_TEMPLATE/issue.md') -Raw

    # Runs one Command in-process; returns { Exit; Output; Error }. Output is every line
    # it printed; Error is the message of the error that stopped it, if one did.
    function Invoke-Command {
        param([Parameter(Mandatory)][string]$Name, [hashtable]$Arguments = @{})
        $global:LASTEXITCODE = 0
        $err = $null
        $lines = try { & (Join-Path $script:Tasks "$Name.ps1") @Arguments *>&1 } catch { $err = $_; @() }
        return [pscustomobject]@{
            Exit   = if ($err) { 1 } else { $LASTEXITCODE }
            Output = (@($lines) + @($err) | Where-Object { $null -ne $_ } | ForEach-Object { "$_" }) -join "`n"
            Error  = if ($err) { "$err" } else { '' }
        }
    }

    # One ISSUES.md block, as the owner writes it below the sentinel.
    function New-IssueBlock {
        param([string]$Title, [string]$Header = '', [string]$Body = (New-IssueBody))
        $head = if ($Header) { "$Header`n" } else { '' }
        $fence = '```'
        return "$fence`nISSUE: $Title`n$head$Body`nEND_ISSUE`n$fence"
    }

    function New-IssuesFile {
        param([string[]]$Blocks)
        return "# Backlog`n`nPromote an item to a block below the ``<!-- ISSUES -->`` sentinel.`n`n<!-- ISSUES -->`n`n$($Blocks -join "`n`n")`n"
    }
}

Describe 'Command journey: sync' {
    AfterEach { Stop-Journey $script:repo }

    It 'turns a block into an issue on the board, with its estimate and priority, and burns the block down' {
        $block = New-IssueBlock -Title 'Greet the visitor by name' -Header "LABELS: enhancement, agent:backlog`nESTIMATE: 3`nPRIORITY: P1"
        $script:repo = Start-Journey -Name 'Commands: sync' -Files @{
            'ISSUES.md' = (New-IssuesFile -Blocks $block); '.github/ISSUE_TEMPLATE/issue.md' = $script:Template
        }
        Set-JourneyBoard

        $run = Invoke-Command sync -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 0 -Because $run.Output
        $global:FakeGitHub.Issues.Count | Should -Be 1
        $issue = @($global:FakeGitHub.Issues.Values)[0]
        $issue.Title | Should -Be 'Greet the visitor by name'
        $issue.Body  | Should -Match '^\*\*Goal\*\*:'
        $issue.Body  | Should -Not -Match 'ESTIMATE:|PRIORITY:|LABELS:'
        # Labels are the pipeline's output: refine sets agent:*, sync never does.
        @($issue.Labels) | Should -Be @('enhancement')
        $item = Get-FakeBoardItem $issue.Number
        $item.estimate | Should -Be 3
        $item.priority | Should -Be 'P1'
        $left = Get-Content -LiteralPath (Join-Path $script:repo.Work 'ISSUES.md') -Raw
        $left | Should -Not -Match 'ISSUE: Greet'
        $left | Should -Not -Match '```' -Because 'the block burns down with its fences'
        $left | Should -Match '<!-- ISSUES -->'
        Assert-FakeGitHubClean
    }

    It 'refuses an ISSUE line outside a fenced block in <Mode>, naming it, and creates nothing' -ForEach @(
        @{ Mode = 'a run';     DryRun = $false }
        @{ Mode = 'a dry run'; DryRun = $true }
    ) {
        $issues = New-IssuesFile -Blocks (New-IssueBlock -Title 'Greet the visitor by name'), "ISSUE: Say goodbye`n$(New-IssueBody)`nEND_ISSUE"
        $script:repo = Start-Journey -Name "Commands: sync unfenced ($Mode)" -Files @{
            'ISSUES.md' = $issues; '.github/ISSUE_TEMPLATE/issue.md' = $script:Template
        }

        $run = Invoke-Command sync -Arguments @{ Root = $script:repo.Work; DryRun = $DryRun }

        $run.Exit | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match 'Unparsed ISSUE block\(s\) — missing fence or malformed'
        $run.Output | Should -Match '• Say goodbye'
        $global:FakeGitHub.Issues.Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $script:repo.Work 'ISSUES.md') -Raw | Should -Be $issues
    }

    It 'refuses every block in <Mode> when one lacks a heading of the issue template, and creates nothing' -ForEach @(
        @{ Mode = 'a run';     DryRun = $false }
        @{ Mode = 'a dry run'; DryRun = $true }
    ) {
        $complete = New-IssueBlock -Title 'Greet the visitor by name'
        $partial  = New-IssueBlock -Title 'Say goodbye' -Body "**Goal**: The visitor is seen off.`n**Description**: Nobody says goodbye today."
        $issues   = New-IssuesFile -Blocks $complete, $partial
        $script:repo = Start-Journey -Name "Commands: sync refuses ($Mode)" -Files @{
            'ISSUES.md' = $issues; '.github/ISSUE_TEMPLATE/issue.md' = $script:Template
        }

        $run = Invoke-Command sync -Arguments @{ Root = $script:repo.Work; DryRun = $DryRun }

        $run.Exit | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match "'Say goodbye' lacks \*\*Requirements\*\*"
        $run.Output | Should -Match "'Say goodbye' lacks \*\*Acceptance Criteria\*\*"
        $run.Output | Should -Not -Match "'Greet the visitor by name' lacks"
        $global:FakeGitHub.Issues.Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $script:repo.Work 'ISSUES.md') -Raw | Should -Be $issues
        Assert-FakeGitHubClean
    }

    It 'changes nothing in a dry run' {
        $issues = New-IssuesFile -Blocks (New-IssueBlock -Title 'Greet the visitor by name' -Header "ESTIMATE: 2`nPRIORITY: P3")
        $script:repo = Start-Journey -Name 'Commands: sync dry run' -Files @{
            'ISSUES.md' = $issues; '.github/ISSUE_TEMPLATE/issue.md' = $script:Template
        }
        Set-JourneyBoard

        $run = Invoke-Command sync -Arguments @{ Root = $script:repo.Work; DryRun = $true }

        $run.Exit | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match '\[DRY RUN\] Would create issue .*estimate: 2, priority: P3'
        $global:FakeGitHub.Issues.Count | Should -Be 0
        $global:FakeGitHub.Board.Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $script:repo.Work 'ISSUES.md') -Raw | Should -Be $issues
        Assert-FakeGitHubClean
    }
}

Describe 'Command journey: setup' {
    AfterEach { Stop-Journey $script:repo }

    It 'writes the board''s ids to .env and the Actions variables, the base labels and the code owners' {
        $script:repo = Start-Journey -Name 'Commands: setup' -Files @{ '.env' = "# the owner's settings`nPORT=8000`nKANBAN_PROJECT_NUMBER=5`nKANBAN_PROJECT_OWNER=octo`n" }

        $run = Invoke-Command setup -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 0 -Because $run.Output
        $board = Get-FakeBoardSettings
        $written = Get-Content -LiteralPath (Join-Path $script:repo.Work '.env')
        foreach ($key in $board.Keys) {
            $written | Should -Contain "$key=$($board[$key])"
            $global:FakeGitHub.Variables[$key] | Should -Be $board[$key]
        }
        # What the owner wrote stays.
        $written | Should -Contain '# the owner''s settings'
        $written | Should -Contain 'PORT=8000'
        $global:FakeGitHub.Variables['KANBAN_RUNNER_PROFILE'] | Should -Be 'hosted'
        foreach ($label in $global:FakeGitHub.PipelineLabels) { $global:FakeGitHub.RepoLabels.Keys | Should -Contain $label }

        $owners = Get-Content -LiteralPath (Join-Path $script:repo.Work '.github/CODEOWNERS')
        $paths  = @(Get-OrchestratorSetting -Name GovernancePaths)
        @($owners | Where-Object { $_ -and -not $_.StartsWith('#') }) | Should -HaveCount $paths.Count
        $owners | Should -Contain "AGENTS.md @$($global:FakeGitHub.Login)"
        $owners | Should -Contain ".github/workflows/ @$($global:FakeGitHub.Login)"
        @($global:FakeGitHub.Changes | Where-Object { $_ -like 'board field * created' }) | Should -BeNullOrEmpty -Because 'the board has every field'
        Assert-FakeGitHubClean
    }

    It 'writes no code-owners file when it cannot read the GitHub login' {
        $script:repo = Start-Journey -Name 'Commands: setup without a login' -Files @{ '.env' = "KANBAN_PROJECT_NUMBER=5`nKANBAN_PROJECT_OWNER=octo`n" }
        $global:FakeGitHub.Login = ''

        $run = Invoke-Command setup -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 0 -Because $run.Output
        Test-Path -LiteralPath (Join-Path $script:repo.Work '.github/CODEOWNERS') | Should -BeFalse
    }

    It 'creates the Estimate and Priority fields a board lacks, and writes their ids' {
        $script:repo = Start-Journey -Name 'Commands: setup creates fields' -Files @{ '.env' = "KANBAN_PROJECT_NUMBER=5`nKANBAN_PROJECT_OWNER=octo`n" }
        $global:FakeGitHub.Project = New-FakeProject -Fields @($global:FakeGitHub.Project.Fields | Where-Object name -eq 'Status')

        $run = Invoke-Command setup -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 0 -Because $run.Output
        @($global:FakeGitHub.Project.Fields.name) | Should -Be @('Status', 'Estimate', 'Priority')
        $written = Get-Content -LiteralPath (Join-Path $script:repo.Work '.env')
        $written | Should -Contain 'KANBAN_ESTIMATE_FIELD_ID=FIELD_estimate'
        $written | Should -Contain 'KANBAN_PRIORITY_OPT_P0=OPT_priority_P0'
        Assert-FakeGitHubClean
    }

    It 'keeps an existing code-owners file as it is' {
        $script:repo = Start-Journey -Name 'Commands: setup keeps code owners' -Files @{
            '.env' = "KANBAN_PROJECT_NUMBER=5`nKANBAN_PROJECT_OWNER=octo`n"; '.github/CODEOWNERS' = "* @someone`n"
        }

        $run = Invoke-Command setup -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 0 -Because $run.Output
        Get-Content -LiteralPath (Join-Path $script:repo.Work '.github/CODEOWNERS') -Raw | Should -Be "* @someone`n"
    }

    It 'stops and says where .env should be when the repository has none, and writes nothing' {
        $script:repo = Start-Journey -Name 'Commands: setup without .env'

        $run = Invoke-Command setup -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 1
        $run.Error | Should -Match '\.env not found at .*\.env'
        Test-Path -LiteralPath (Join-Path $script:repo.Work '.env') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:repo.Work '.github/CODEOWNERS') | Should -BeFalse
        $global:FakeGitHub.Calls | Should -BeNullOrEmpty
    }
}

Describe 'Command journey: protect' {
    AfterEach { Stop-Journey $script:repo }

    It 'applies the required checks, the branch rules and the merge settings on a public repository, then verifies them' {
        $script:repo = Start-Journey -Name 'Commands: protect'

        $run = Invoke-Command protect -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 0 -Because $run.Output
        $required = @(Get-OrchestratorSetting -Name RequiredChecks)
        $rules = $global:FakeGitHub.Protection
        @($rules.required_status_checks.contexts) | Should -Be $required
        $rules.required_status_checks.strict | Should -BeFalse
        $rules.enforce_admins | Should -BeTrue
        $rules.required_pull_request_reviews.required_approving_review_count | Should -Be 0
        $rules.allow_force_pushes | Should -BeFalse
        $settings = $global:FakeGitHub.RepoSettings
        $settings.allow_squash_merge | Should -BeTrue
        $settings.allow_merge_commit | Should -BeFalse
        $settings.allow_rebase_merge | Should -BeFalse
        $settings.squash_merge_commit_title | Should -Be 'PR_TITLE'
        $settings.delete_branch_on_merge | Should -BeTrue
        $settings.security_and_analysis.secret_scanning.status | Should -Be 'enabled'
        $settings.security_and_analysis.secret_scanning_push_protection.status | Should -Be 'enabled'
        # Branch rules first, then the merge settings in a call of their own, then secret scanning.
        @($global:FakeGitHub.Changes) | Should -Be @(
            'branch protection of main', "repository settings: $('allow_squash_merge, allow_merge_commit, allow_rebase_merge, squash_merge_commit_title, squash_merge_commit_message, delete_branch_on_merge, allow_update_branch')",
            'repository settings: security_and_analysis')
        $run.Output | Should -Match "✅ All $($required.Count) required status checks configured\."
        $run.Output | Should -Match '✅ Up-to-date requirement off'
        $run.Output | Should -Match '✅ Admin bypass disabled'
        $run.Output | Should -Match '✅ Merge setting allow_merge_commit: false\.'
        $run.Output | Should -Match '✅ Push protection enabled'
        $run.Output | Should -Not -Match '⚠️'
        Assert-FakeGitHubClean
    }

    It 'fails when a public repository refuses secret scanning, with the branch rules and merge settings already applied' {
        $script:repo = Start-Journey -Name 'Commands: protect public refusal'
        $global:FakeGitHub.RefuseSecretScanning = $true

        $run = Invoke-Command protect -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 1
        $run.Error | Should -Match 'Failed to switch on secret scanning and push protection'
        $global:FakeGitHub.Protection | Should -Not -BeNullOrEmpty
        $global:FakeGitHub.RepoSettings.allow_merge_commit | Should -BeFalse
        Assert-FakeGitHubClean
    }

    It 'reports a private repository''s refused secret scanning once and keeps the branch rules and merge settings' {
        $script:repo = Start-Journey -Name 'Commands: protect private'
        $global:FakeGitHub.RepoSettings.visibility = 'private'

        $run = Invoke-Command protect -Arguments @{ Root = $script:repo.Work }

        $run.Exit | Should -Be 0 -Because $run.Output
        $global:FakeGitHub.Protection | Should -Not -BeNullOrEmpty
        $global:FakeGitHub.RepoSettings.allow_merge_commit | Should -BeFalse
        @([regex]::Matches($run.Output, 'GitHub Secret Protection provides it')).Count | Should -Be 1
        $run.Output | Should -Match '⚠️  Secret scanning not enabled \(secret_scanning: disabled\)'
        $run.Output | Should -Match '✅ Merge setting delete_branch_on_merge: true\.'
        Assert-FakeGitHubClean
    }
}
