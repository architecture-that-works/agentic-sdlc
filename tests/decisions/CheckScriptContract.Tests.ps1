#Requires -Version 7.0
<#
    Decision table — check-script-contract.ps1: the Library/Runnable contract (ADR-013).
    Each row writes a few scripts into a temporary repository, runs the check, and asserts
    the exit code and the violation line it prints, naming the file and the rule.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Check = 'check-script-contract.ps1'
    $script:Base = @{
        '.github/orchestrator/Orchestrator.psm1' = "#Requires -Version 7.0`n. `"`$PSScriptRoot\lib\Config.ps1`"`n"
        '.github/orchestrator/lib/Config.ps1'    = "#Requires -Version 7.0`n`$KanbanRepo = 'octo/sandbox'`n"
        '.github/tasks/Settings.ps1'             = "#Requires -Version 7.0`nfunction Import-Settings { param([string]`$Root) }`n"
        '.github/tasks/demo.ps1'                 = "#Requires -Version 7.0`nparam([int]`$Issue = 0)`n. `"`$PSScriptRoot\Settings.ps1`"`nImport-Module `"`$PSScriptRoot\..\orchestrator\Orchestrator.psm1`"`n"
        '.agents/skills/demo/scripts/probe.ps1'  = "#Requires -Version 7.0`nparam([string]`$Body = '')`n"
    }
}

Describe 'Decision: check-script-contract' {
    AfterEach { Remove-CheckRepo $script:root }

    It '<Case> — exit <Exit>' -ForEach @(
        @{ Case = 'libraries without param(), runnables with their own'; Exit = 0; Files = @{} }
        @{ Case = 'a script without #Requires'; Exit = 1; Line = '.github/tasks/demo.ps1: requires'
           Files = @{ '.github/tasks/demo.ps1' = "param([int]`$Issue = 0)`n" } }
        @{ Case = 'a script requiring PowerShell 5'; Exit = 1; Line = '.agents/skills/demo/scripts/probe.ps1: requires'
           Files = @{ '.agents/skills/demo/scripts/probe.ps1' = "#Requires -Version 5.1`n" } }
        @{ Case = 'a library with a top-level param()'; Exit = 1; Line = '.github/orchestrator/lib/Config.ps1: library — dot-sourced by .github/orchestrator/Orchestrator.psm1'
           Files = @{ '.github/orchestrator/lib/Config.ps1' = "#Requires -Version 7.0`nparam([int]`$Issue = 0)`n" } }
        @{ Case = 'a PascalCase file with a param() that nothing dot-sources'; Exit = 1; Line = '.github/orchestrator/lib/Extra.ps1: library — a Library (PascalCase)'
           Files = @{ '.github/orchestrator/lib/Extra.ps1' = "#Requires -Version 7.0`nparam([string]`$Name)`n" } }
        @{ Case = 'a function''s own param() in a library'; Exit = 0
           Files = @{ '.github/orchestrator/lib/Config.ps1' = "#Requires -Version 7.0`nfunction Get-X {`n    param([int]`$Issue = 0)`n}`n" } }
        @{ Case = 'a runnable that is dot-sourced'; Exit = 1; Line = '.agents/skills/demo/scripts/probe.ps1: runnable — a Runnable (lowercase) dot-sourced by .github/tasks/demo.ps1'
           Files = @{ '.github/tasks/demo.ps1' = "#Requires -Version 7.0`n. `"`$PSScriptRoot\..\..\.agents\skills\demo\scripts\probe.ps1`"`n"
                      '.agents/skills/demo/scripts/probe.ps1' = "#Requires -Version 7.0`nWrite-Output 'probe'`n" } }
        @{ Case = 'a path that points at nothing'; Exit = 1; Line = '.github/tasks/demo.ps1: path — $PSScriptRoot\..\..\..\orchestrator\Orchestrator.psm1 points at a place outside the repository'
           Files = @{ '.github/tasks/demo.ps1' = "#Requires -Version 7.0`nImport-Module `"`$PSScriptRoot\..\..\..\orchestrator\Orchestrator.psm1`"`n" } }
        @{ Case = 'a path inside the repository that is gone'; Exit = 1; Line = '.github/tasks/demo.ps1: path — $PSScriptRoot\Gone.ps1 points at .github/tasks/Gone.ps1'
           Files = @{ '.github/tasks/demo.ps1' = "#Requires -Version 7.0`n. `"`$PSScriptRoot\Gone.ps1`"`n" } }
        @{ Case = 'a Command that uses the module''s run state without setting it'; Exit = 1; Line = '.github/tasks/demo.ps1: state — uses $KanbanRepo without setting it'
           Files = @{ '.github/tasks/demo.ps1' = "#Requires -Version 7.0`ngh issue list --repo `$KanbanRepo`n" } }
        @{ Case = 'a Command that sets the run state it uses'; Exit = 0
           Files = @{ '.github/tasks/demo.ps1' = "#Requires -Version 7.0`n`$KanbanRepo = 'octo/sandbox'`ngh issue list --repo `$KanbanRepo`n" } }
    ) {
        $script:root = New-CheckRepo -Check $script:Check -Files $script:Base, $Files -NoGit

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be $Exit -Because $run.Output
        if ($Line) {
            $run.Output | Should -Match ([regex]::Escape($Line))
            @($run.Lines | Where-Object { $_ -like '❌ *: *' -and $_ -notlike '❌ * violation(s)*' }).Count | Should -Be 1 -Because $run.Output
        }
    }
}
