#Requires -Version 7.0
<#
    State-machine report — runs last in the Pester run (.github/tasks/test.ps1 orders it
    so) and reads every label transition the fake GitHub recorded across the journeys
    ($global:OrchestratorJourneyTransitions).

    It fails, naming the transition, when a journey moved an issue into a state from a
    label that state's AllowedFrom in $PipelineStates (lib/Config.ps1) does not list.
    The table is never widened to make it pass: a refused transition means the journey
    left the designed path somewhere (CONTEXT.md, "The state machine is rigid").

    It then checks that every designed transition — every AllowedFrom entry — was
    exercised: it fails, naming each one no table or journey caused. An entry nothing in
    the orchestrator can cause is removed from the table, never kept on a list of
    exceptions. Run alone ($global:OrchestratorJourneyStarts zero or unset: no journey
    or table started), it lists them and passes, as the export-reach report skips.
#>

BeforeDiscovery {
    # One test per designed transition, so a failure names it. The table is read from
    # the syntax of lib/Config.ps1, not by importing the module: an import during
    # discovery runs before Pester's coverage is set up and hides the lines it ran.
    $config = Join-Path $PSScriptRoot '../../.github/orchestrator/lib/Config.ps1'
    $ast    = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $config).ProviderPath, [ref]$null, [ref]$null)
    $assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -eq '$PipelineStates' }, $false)
    $table  = $assign.Right.Expression.Child.SafeGetValue()   # [ordered]@{…} → its @{…}
    $script:DesignedCases = @(foreach ($to in $table.Keys) {
        foreach ($from in @($table[$to].AllowedFrom)) {
            $name = "$(if ($null -eq $from) { '(none)' } else { $from }) → $to"
            @{ Name = $name; Transition = [pscustomobject]@{ From = $from; To = $to } }
        }
    })
}

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
    $script:Seen = @{}
    foreach ($t in $script:Recorded) { $script:Seen[(Format-Transition $t)] = $true }

    # True when the fake GitHub recorded the transition in this Pester run.
    function Test-Exercised {
        param($T)
        return $script:Seen.ContainsKey((Format-Transition $T))
    }
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

    It 'lists the designed transitions and those not exercised' {
        $missing = @($script:Designed | Where-Object { -not (Test-Exercised $_) })
        Write-Host ''
        Write-Host "State machine: $($script:Designed.Count - $missing.Count) of $($script:Designed.Count) designed transitions exercised by the journeys."
        foreach ($t in $missing) { Write-Host "  not exercised: $(Format-Transition $t)" }
        foreach ($t in @($script:Recorded | Where-Object { $null -eq $_.To })) {
            Write-Host "  label removed without a successor: $(Format-Transition $t) (issue #$($t.Issue), $($t.Journey))"
        }
        $script:Designed.Count | Should -BeGreaterThan 0
    }

    It 'a journey or table exercises <Name>' -ForEach $script:DesignedCases {
        if (-not $global:OrchestratorJourneyStarts) {
            Set-ItResult -Skipped -Because 'no journey or table ran in this Pester run — run .github/tasks/test.ps1'
            return
        }
        Test-Exercised $Transition | Should -BeTrue -Because "$Name is an AllowedFrom entry of `$PipelineStates (lib/Config.ps1), and no journey or table caused it — cause it the way the real run does, or remove the entry when nothing in the orchestrator can"
    }
}
