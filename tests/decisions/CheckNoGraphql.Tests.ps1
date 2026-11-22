#Requires -Version 7.0
<#
    Decision table — check-no-graphql.ps1: no GraphQL call where REST or the run context
    serves (ADR-012). Each row writes one line into a script or workflow, runs the check,
    and asserts the exit code and the line naming the file, the line number and the rule.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Check = 'check-no-graphql.ps1'
    $script:Base = @{
        '.github/orchestrator/lib/Config.ps1' = "#Requires -Version 7.0`n`$KanbanRepo = `$env:GITHUB_REPOSITORY`n"
        '.github/orchestrator/stages/Ship.ps1' = "#Requires -Version 7.0`nfunction Invoke-Ship { }`n"
        '.github/tasks/sync.ps1'               = "#Requires -Version 7.0`n`$Repo = (Get-OrchestratorContext).Repo`n"
        '.github/workflows/afk.yml'            = "jobs:`n  run:`n    steps:`n      - run: echo `$GITHUB_DEFAULT_BRANCH`n"
    }
}

Describe 'Decision: check-no-graphql' {
    AfterEach { Remove-CheckRepo $script:root }

    It '<Case> — exit <Exit>' -ForEach @(
        @{ Case = 'the slug from the run context'; Exit = 0; Files = @{} }
        @{ Case = 'gh repo view in a stage'; Exit = 1; Line = '.github/orchestrator/stages/Ship.ps1:2: repo view is a GraphQL call'
           Files = @{ '.github/orchestrator/stages/Ship.ps1' = "#Requires -Version 7.0`n`$b = gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'`n" } }
        @{ Case = 'gh repo view in a Command'; Exit = 1; Line = '.github/tasks/sync.ps1:2: repo view is a GraphQL call'
           Files = @{ '.github/tasks/sync.ps1' = "#Requires -Version 7.0`n`$Repo = gh repo view --json nameWithOwner --jq '.nameWithOwner'`n" } }
        @{ Case = 'gh repo view in a workflow'; Exit = 1; Line = '.github/workflows/afk.yml:4: repo view is a GraphQL call'
           Files = @{ '.github/workflows/afk.yml' = "jobs:`n  run:`n    steps:`n      - run: gh repo view --json defaultBranchRef`n" } }
        @{ Case = 'the guarded last-resort fallback in Config.ps1'; Exit = 0
           Files = @{ '.github/orchestrator/lib/Config.ps1' = "#Requires -Version 7.0`n`$KanbanRepo = gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>`$null`n" } }
        @{ Case = 'an unguarded gh repo view in Config.ps1'; Exit = 1; Line = '.github/orchestrator/lib/Config.ps1:2: repo view is a GraphQL call'
           Files = @{ '.github/orchestrator/lib/Config.ps1' = "#Requires -Version 7.0`n`$KanbanRepo = gh repo view --json nameWithOwner --jq '.nameWithOwner'`n" } }
        @{ Case = 'a label added with gh issue edit'; Exit = 1; Line = '.github/orchestrator/stages/Ship.ps1:2: label write is a GraphQL call'
           Files = @{ '.github/orchestrator/stages/Ship.ps1' = "#Requires -Version 7.0`ngh issue edit 5 --add-label agent:shipped`n" } }
        @{ Case = 'labels read with gh issue view'; Exit = 1; Line = '.github/orchestrator/stages/Ship.ps1:2: label read is a GraphQL call'
           Files = @{ '.github/orchestrator/stages/Ship.ps1' = "#Requires -Version 7.0`n`$l = gh issue view 5 --json labels`n" } }
        @{ Case = 'labels read with gh issue view split by a backtick'; Exit = 1; Line = '.github/workflows/afk.yml:4: label read is a GraphQL call'
           Files = @{ '.github/workflows/afk.yml' = "jobs:`n  run:`n    steps:`n      - run: `$l = gh issue view 5 --repo x/y ```n          --json labels --jq '.labels[].name'`n" } }
        @{ Case = 'labels read through REST, split by a backtick'; Exit = 0
           Files = @{ '.github/workflows/afk.yml' = "jobs:`n  run:`n    steps:`n      - run: `$l = gh api repos/x/y/issues/5/labels ```n          --jq '[.[].name]'`n" } }
        @{ Case = 'gh repo view in a comment'; Exit = 0
           Files = @{ '.github/orchestrator/stages/Ship.ps1' = "#Requires -Version 7.0`n# never gh repo view here`n<#`n  gh repo view is GraphQL`n#>`n" } }
        @{ Case = 'a Projects v2 call'; Exit = 0
           Files = @{ '.github/orchestrator/stages/Ship.ps1' = "#Requires -Version 7.0`ngh project item-edit --id x --field-id y`n" } }
    ) {
        $script:root = New-CheckRepo -Check $script:Check -Files $script:Base, $Files -NoGit

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be $Exit -Because $run.Output
        if ($Line) { $run.Output | Should -Match ([regex]::Escape($Line)) }
    }
}
