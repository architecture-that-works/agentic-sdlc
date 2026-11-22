#Requires -Version 7.0
<#
    Decision table — check-orchestrator-api.ps1: code outside the orchestrator calls only
    the functions Orchestrator.psd1 exports, and every export has an outside caller. Each
    row writes a module with one exported and one private function and a caller, runs the
    check, and asserts the exit code and the violation it names.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Check = 'check-orchestrator-api.ps1'
    $script:Module = @{
        '.github/orchestrator/Orchestrator.psd1'  = "@{ RootModule = 'Orchestrator.psm1'; FunctionsToExport = @('Invoke-Public') }`n"
        '.github/orchestrator/Orchestrator.psm1'  = "#Requires -Version 7.0`nfunction Invoke-Public { Get-Private }`n"
        '.github/orchestrator/lib/Private.ps1'    = "#Requires -Version 7.0`nfunction Get-Private { 1 }`n"
        '.github/workflows/afk.yml'               = "jobs:`n  run:`n    steps:`n      - run: Invoke-Public`n"
        '.github/tasks/demo.ps1'                  = "#Requires -Version 7.0`nWrite-Output 'demo'`n"
        '.agents/skills/demo/scripts/probe.ps1'   = "#Requires -Version 7.0`nWrite-Output 'probe'`n"
    }
}

Describe 'Decision: check-orchestrator-api' {
    AfterEach { Remove-CheckRepo $script:root }

    It '<Case> — exit <Exit>' -ForEach @(
        @{ Case = 'every export is called and nothing private is'; Exit = 0; Files = @{} }
        @{ Case = 'a Command calls a private function'; Exit = 1; Line = "demo.ps1 calls private orchestrator function 'Get-Private'"
           Files = @{ '.github/tasks/demo.ps1' = "#Requires -Version 7.0`nGet-Private`n" } }
        @{ Case = 'a skill script calls a private function'; Exit = 1; Line = "probe.ps1 calls private orchestrator function 'Get-Private'"
           Files = @{ '.agents/skills/demo/scripts/probe.ps1' = "#Requires -Version 7.0`nGet-Private`n" } }
        @{ Case = 'nothing outside calls an export'; Exit = 1; Line = "'Invoke-Public' is exported but nothing outside the orchestrator calls it"
           Files = @{ '.github/workflows/afk.yml' = "jobs:`n  run:`n    steps:`n      - run: echo nothing`n" } }
        @{ Case = 'a Command calls the export'; Exit = 0
           Files = @{ '.github/workflows/afk.yml' = "jobs: {}`n"; '.github/tasks/demo.ps1' = "#Requires -Version 7.0`nInvoke-Public`n" } }
        @{ Case = 'the manifest lists no exports'; Exit = 1; Line = 'Could not parse FunctionsToExport from Orchestrator.psd1'
           Files = @{ '.github/orchestrator/Orchestrator.psd1' = "@{ RootModule = 'Orchestrator.psm1' }`n" } }
    ) {
        $script:root = New-CheckRepo -Check $script:Check -Files $script:Module, $Files -NoGit

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be $Exit -Because $run.Output
        if ($Line) { $run.Output | Should -Match ([regex]::Escape($Line)) }
    }
}
