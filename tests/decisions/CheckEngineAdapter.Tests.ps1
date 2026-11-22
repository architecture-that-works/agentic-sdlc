#Requires -Version 7.0
<#
    Decision table — check-engine-adapter.ps1: only an engine adapter starts the engine's
    CLI or names its flags, and nothing pins the engine by name. Each row writes one line,
    runs the check, and asserts the exit code and the line naming the file and the rule.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Check = 'check-engine-adapter.ps1'
    $script:Base = @{
        '.github/orchestrator/engines/Claude.ps1' = "#Requires -Version 7.0`n`$Prompt | claude @CliArgs`n`$a = @('--model', `$m, '--max-turns', 5)`n"
        '.github/orchestrator/stages/Review.ps1'  = "#Requires -Version 7.0`nInvoke-EngineTask -Task Review -Prompt `$p -Label Review`n"
        '.agents/skills/demo/SKILL.md'            = "# Demo`n"
    }
}

Describe 'Decision: check-engine-adapter' {
    AfterEach { Remove-CheckRepo $script:root }

    It '<Case> — exit <Exit>' -ForEach @(
        @{ Case = 'the CLI and its flags only in the adapter'; Exit = 0; Files = @{} }
        @{ Case = 'a stage that names a model flag'; Exit = 1; Line = '.github/orchestrator/stages/Review.ps1:2: cli'
           Files = @{ '.github/orchestrator/stages/Review.ps1' = "#Requires -Version 7.0`n`$args = @('--model', 'x')`n" } }
        @{ Case = 'a library that starts the CLI'; Exit = 1; Line = '.github/orchestrator/lib/Util.ps1:2: cli'
           Files = @{ '.github/orchestrator/lib/Util.ps1' = "#Requires -Version 7.0`n'ping' | claude -p`n" } }
        @{ Case = 'a skill document that names a CLI flag'; Exit = 1; Line = '.agents/skills/demo/SKILL.md:1: cli'
           Files = @{ '.agents/skills/demo/SKILL.md' = "Run with --json-schema to get an answer.`n" } }
        @{ Case = 'a workflow that pins the engine'; Exit = 1; Line = '.github/workflows/afk.yml:1: pin'
           Files = @{ '.github/workflows/afk.yml' = "- run: Invoke-Grill -Engine 'claude'`n" } }
    ) {
        $script:root = New-CheckRepo -Check $script:Check -Files $script:Base, $Files -NoGit

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be $Exit -Because $run.Output
        if ($Line) { $run.Output | Should -Match ([regex]::Escape($Line)) }
    }
}
