#Requires -Version 7.0
<#
    State-machine report — runs last in the Pester run (.github/tasks/test.ps1 orders it
    so) and reads every label transition the fake GitHub recorded across the journeys
    ($global:OrchestratorJourneyTransitions).

    It fails, naming the transition, when a journey moved an issue into a state from a
    label that state's AllowedFrom in $PipelineStates (lib/Config.ps1) does not list.
    The table is never widened to make it pass: a refused transition means the journey
    left the designed path somewhere (CONTEXT.md, "The state machine is rigid").

    It then lists the designed transitions — every AllowedFrom entry — that no journey
    caused yet. Run alone, no journey ran, so it lists them all and passes.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')

    # Every designed transition: one per AllowedFrom entry, { From; To }, From $null
    # for "no pipeline label".
    function Get-DesignedTransitions {
        $table = & (Get-Module Orchestrator) { $PipelineStates }
        foreach ($to in $table.Keys) {
            foreach ($from in @($table[$to].AllowedFrom)) { [pscustomobject]@{ From = $from; To = $to } }
        }
    }

    function Format-Transition {
        param($T)
        $from = if ($null -eq $T.From) { '(none)' } else { $T.From }
        $to   = if ($null -eq $T.To) { '(none)' } else { $T.To }
        return "$from → $to"
    }

    # The recorded transitions into a pipeline state that its AllowedFrom refuses.
    function Get-RefusedTransitions {
        param([object[]]$Recorded)
        $table = & (Get-Module Orchestrator) { $PipelineStates }
        return @($Recorded | Where-Object {
            $null -ne $_.To -and (-not $table.Contains($_.To) -or -not (@($table[$_.To].AllowedFrom) -contains $_.From))
        })
    }

    $script:Recorded = @($global:OrchestratorJourneyTransitions | Where-Object { $_ })
    $script:Designed = @(Get-DesignedTransitions)
}

Describe 'State machine' {
    It 'refuses a transition the table does not allow' {
        # The check itself, on a transition no state allows: agent:shipped is terminal.
        $refused = Get-RefusedTransitions -Recorded @([pscustomobject]@{ Journey = 'self-check'; Issue = 1; From = 'agent:shipped'; To = 'agent:backlog' })
        @($refused).Count | Should -Be 1
    }

    It 'saw only transitions the table allows' {
        $refused = @(Get-RefusedTransitions -Recorded $script:Recorded)
        $names   = @($refused | ForEach-Object { "$(Format-Transition $_) (issue #$($_.Issue), $($_.Journey))" })
        $names | Should -BeNullOrEmpty -Because "these transitions are not in `$PipelineStates AllowedFrom: $($names -join '; ')"
    }

    It 'lists the designed transitions no journey exercised yet' {
        $seen = @{}
        foreach ($t in $script:Recorded) { $seen[(Format-Transition $t)] = $true }
        $missing = @($script:Designed | Where-Object { -not $seen.ContainsKey((Format-Transition $_)) })
        $done    = $script:Designed.Count - $missing.Count

        Write-Host ''
        Write-Host "State machine: $done of $($script:Designed.Count) designed transitions exercised by the journeys."
        foreach ($t in $missing) { Write-Host "  not exercised yet: $(Format-Transition $t)" }
        foreach ($t in @($script:Recorded | Where-Object { $null -eq $_.To })) {
            Write-Host "  label removed without a successor: $(Format-Transition $t) (issue #$($t.Issue), $($t.Journey))"
        }

        $script:Designed.Count | Should -BeGreaterThan 0
    }
}
