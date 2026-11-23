#Requires -Version 7.0
<#
    Decision table — check-settings-read.ps1: every key of the settings table
    ($OrchestratorConfig in lib/Config.ps1) is read by the orchestrator or a Command. Each
    row writes a table of two settings and one way of reading the second, runs the check,
    and asserts the exit code and the line naming a setting nothing reads.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Check = 'check-settings-read.ps1'
    $script:Config = "#Requires -Version 7.0`n`$OrchestratorConfig = @{`n    MaxRetries = 3`n    Waited = 10`n}`n"
    function New-Reader { param([string]$Line) "#Requires -Version 7.0`n`$n = `$OrchestratorConfig.MaxRetries`n$Line`n" }
}

Describe 'Decision: check-settings-read' {
    AfterEach { Remove-CheckRepo $script:root }

    It 'a setting read <Case> — exit <Exit>' -ForEach @(
        @{ Case = 'as a member';                   Exit = 0; Where = '.github/orchestrator/stages/Ship.ps1'; Line = '$w = $OrchestratorConfig.Waited' }
        @{ Case = 'by index';                      Exit = 0; Where = '.github/orchestrator/stages/Ship.ps1'; Line = "`$w = `$OrchestratorConfig['Waited']" }
        @{ Case = 'inside a string';               Exit = 0; Where = '.github/orchestrator/stages/Ship.ps1'; Line = '$w = "$($OrchestratorConfig.Waited)s"' }
        @{ Case = 'by a Command';                  Exit = 0; Where = '.github/tasks/demo.ps1';               Line = '$w = $OrchestratorConfig.Waited' }
        @{ Case = 'nowhere';                       Exit = 1; Where = '.github/orchestrator/stages/Ship.ps1'; Line = '' }
        @{ Case = 'only in a comment';             Exit = 1; Where = '.github/orchestrator/stages/Ship.ps1'; Line = '# $OrchestratorConfig.Waited is not read' }
        @{ Case = 'only in a block comment';       Exit = 1; Where = '.github/orchestrator/stages/Ship.ps1'; Line = '<# $OrchestratorConfig.Waited #>' }
        @{ Case = 'as another object''s property'; Exit = 1; Where = '.github/orchestrator/stages/Ship.ps1'; Line = '$w = $ctx.Waited' }
    ) {
        $script:root = New-CheckRepo -Check $script:Check -NoGit -Files @{
            '.github/orchestrator/lib/Config.ps1' = $script:Config
            $Where                                 = (New-Reader -Line $Line)
        }

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be $Exit -Because $run.Output
        if ($Exit -eq 1) {
            $run.Output | Should -Match "The setting 'Waited' in \.github/orchestrator/lib/Config\.ps1 is read by nothing"
            $run.Output | Should -Not -Match "'MaxRetries'"
        }
    }

    It 'stops, naming the file, when the settings table is missing' {
        $script:root = New-CheckRepo -Check $script:Check -NoGit

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be 1
        $run.Output | Should -Match 'lib/Config\.ps1 is missing'
    }
}
