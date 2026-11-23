#Requires -Version 7.0
<#
    Export-reach report — runs last in the Pester run, beside the state-machine report
    (.github/tasks/test.ps1 orders them so), and reads which exported functions the
    decision tables and journeys reached ($global:OrchestratorExportReach).

    tests/journeys/Journey.ps1 sets a recording-only breakpoint on every function in
    Orchestrator.psd1 FunctionsToExport when it imports the module, so a call counts
    wherever it comes from: a journey, a table, a Command run in-process, or the module
    itself. This fails once for each export nothing reached, naming it — the public
    surface is what the workflows and Commands call, so each export is a path some test
    must walk. Never widen FunctionsToExport to make it pass, and never satisfy it with
    a test that calls a function for its own sake.

    Run alone, no journey or table ran, so there is nothing to report and it is skipped.
#>

BeforeDiscovery {
    $script:Exports = @((Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '../../.github/orchestrator/Orchestrator.psd1')).FunctionsToExport)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')
}

Describe 'Export reach' {
    It 'the journeys and tables reach <_>' -ForEach $script:Exports {
        if (-not $global:OrchestratorJourneyStarts) {
            Set-ItResult -Skipped -Because 'no journey or table ran in this Pester run — run .github/tasks/test.ps1'
            return
        }
        $reached = $global:OrchestratorExportReach -and $global:OrchestratorExportReach.ContainsKey($_)
        $reached | Should -BeTrue -Because "'$_' is exported by Orchestrator.psd1, and no journey or table called it"
    }
}
