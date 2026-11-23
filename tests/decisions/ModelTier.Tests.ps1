#Requires -Version 7.0
<#
    Decision table — which model a task runs on: the task's tier (TaskTiers), then that
    tier's model in the row of the engine the Engine setting names (Engines), and the
    missing value that stops a run, naming the key to fill, instead of falling back to
    another model. Each row starts the engine call for one task against the stand-in CLI
    (tests/fakes/Cli.ps1) and asserts the model it was started with, or the error.

    The expected model is read from the settings table (lib/Config.ps1) — the one place
    it is written — never copied here.

    Then: the estimate on the board chooses the implement task (ImplementLarge from
    ImplementLargeFrom story points, ImplementSmall below it and with no estimate),
    entered through the conductor on a board the row states.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')

    # Runs -Body with the setting -Name changed by -Change (a scriptblock over a copy), then
    # puts the setting back.
    function Use-ChangedSetting {
        param([string]$Name, [scriptblock]$Change, [scriptblock]$Body)
        $saved = Get-OrchestratorSetting -Name $Name
        $copy = if ($saved -is [hashtable]) { $saved.Clone() } else { $saved }
        try {
            Set-OrchestratorSetting -Name $Name -Value (& $Change $copy)
            & $Body
        } finally {
            Set-OrchestratorSetting -Name $Name -Value $saved
        }
    }
}

Describe 'Decision: the model of a task' {
    BeforeEach {
        $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" -RealEngine
        $null = New-FakeCli -Attempts @(@{ Result = @{ subtype = 'success'; result = 'ok' } })
        Install-FakeCli
    }
    AfterEach {
        Remove-FakeCli
        Stop-Journey $script:repo
    }

    It '<Task> runs on its tier''s model' -ForEach @(
        @{ Task = 'Refine' }
        @{ Task = 'Plan' }
        @{ Task = 'ImplementLarge' }
        @{ Task = 'ImplementSmall' }
        @{ Task = 'Review' }
        @{ Task = 'CommitMessage' }
        @{ Task = 'EngineCheck' }
    ) {
        $engine = Get-OrchestratorSetting -Name Engine
        $tier   = (Get-OrchestratorSetting -Name TaskTiers)[$Task]
        $model  = (Get-OrchestratorSetting -Name Engines)[$engine][$tier]
        $tier  | Should -BeIn @('routine', 'standard', 'complex')
        $model | Should -Not -BeNullOrEmpty

        $null = Invoke-EngineAtSeam @{ Task = $Task; Prompt = 'p'; Label = $Task }

        Get-FakeCliFlag (Get-FakeCliCalls)[0] '--model' | Should -Be $model
    }

    It 'a task with no tier stops the call, naming TaskTiers.<Task>' -ForEach @(@{ Task = 'Deploy' }) {
        { Invoke-EngineAtSeam @{ Task = $Task; Prompt = 'p'; Label = $Task } } | Should -Throw "*task '$Task' has no tier — fill TaskTiers.$Task*"
        Get-FakeCliCalls | Should -BeNullOrEmpty
    }

    It 'a tier the engine has no model for stops the call, naming the engine''s tier' {
        $engine = Get-OrchestratorSetting -Name Engine
        $tier   = (Get-OrchestratorSetting -Name TaskTiers)['CommitMessage']
        Use-ChangedSetting -Name Engines -Change { param($e) $row = $e[$engine].Clone(); $row.Remove($tier); $e[$engine] = $row; $e } -Body {
            { Invoke-EngineAtSeam @{ Task = 'CommitMessage'; Prompt = 'p'; Label = 'Commit' } } |
                Should -Throw "*task 'CommitMessage' is tier '$tier', and engine '$engine' has no model for it — fill Engines.$engine.$tier*"
        }
        Get-FakeCliCalls | Should -BeNullOrEmpty
    }

    It 'an engine with no row stops the call, naming its row' {
        Use-ChangedSetting -Name Engine -Change { 'other' } -Body {
            { Invoke-EngineAtSeam @{ Task = 'Review'; Prompt = 'p'; Label = 'Review' } } | Should -Throw "*runs on engine 'other', which has no row — fill Engines.other*"
        }
        Get-FakeCliCalls | Should -BeNullOrEmpty
    }

    It 'a missing value stops a run before any stage, naming the key, and changes nothing' {
        Add-FakeIssue -Number 80 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 80) -Labels @('agent:backlog')
        Use-ChangedSetting -Name TaskTiers -Change { param($t) $t.Remove('EngineCheck'); $t } -Body {
            { Invoke-Orchestration -IssueNumber 80 -From implement } | Should -Throw '*fill TaskTiers.EngineCheck*'
        }
        Get-FakePipelineLabel 80 | Should -Be 'agent:backlog'
        Get-FakeComments 80 | Should -BeNullOrEmpty
        Get-FakeCliCalls | Should -BeNullOrEmpty
    }
}

Describe 'Decision: the engine the Engine setting names' {
    It 'an Engine with no adapter in engines/ stops the module at import, naming the setting' {
        $copy = Join-Path ([System.IO.Path]::GetTempPath()) "engine-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        try {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../.github/orchestrator') -Destination $copy -Recurse
            $config = Join-Path $copy 'lib/Config.ps1'
            $text = Get-Content -LiteralPath $config -Raw
            $text | Should -Match "Engine = 'claude'"
            Set-Content -LiteralPath $config -Value ($text -replace "Engine = 'claude'", "Engine = 'other'") -Encoding utf8NoBOM -NoNewline
            $manifest = Join-Path $copy 'Orchestrator.psd1'
            $env:ENGINE_TABLE_MODULE = $manifest
            $out = & pwsh -NoProfile -Command '$env:GITHUB_REPOSITORY = "octo/sandbox"; $env:GITHUB_DEFAULT_BRANCH = "main"; Import-Module $env:ENGINE_TABLE_MODULE -DisableNameChecking' 2>&1 | Out-String
            $LASTEXITCODE | Should -Not -Be 0
            $out | Should -Match "The Engine setting 'other' \(lib/Config\.ps1\) names no engine adapter"
        } finally {
            $env:ENGINE_TABLE_MODULE = $null
            Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Decision: the implement task' {
    BeforeEach { $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" -Files (Get-JourneyFiles) }
    AfterEach { Stop-Journey $script:repo }

    It 'an estimate <Case> runs <Task>' -ForEach @(
        @{ Case = 'not set';                         Offset = $null; Task = 'ImplementSmall' }
        @{ Case = 'one below ImplementLargeFrom';    Offset = -1;    Task = 'ImplementSmall' }
        @{ Case = 'of ImplementLargeFrom';           Offset = 0;     Task = 'ImplementLarge' }
        @{ Case = 'well above ImplementLargeFrom';   Offset = 5;     Task = 'ImplementLarge' }
    ) {
        Set-JourneyBoard
        $estimate = if ($null -ne $Offset) { (Get-OrchestratorSetting -Name ImplementLargeFrom) + $Offset } else { $null }
        Add-FakeIssue -Number 81 -Title 'Describe the decisions' -Body (New-PlannedIssueBody -Number 81) -Labels @('agent:backlog')
        Add-FakeBoardItem -Issue 81 -Status 'Backlog' -Estimate $estimate
        Add-ImplementRun -Task $Task -Edits @{ 'docs/decisions.md' = "# Decisions`n" } -Message 'docs(#81): describe the decisions'
        Add-ReviewVerdict

        Invoke-Orchestration -IssueNumber 81 -From implement

        @(Get-FakeEngineCalls | Where-Object { $_.Task -like 'Implement*' } | ForEach-Object Task) | Should -Be @($Task) -Because (Get-JourneyStory 81)
        Get-FakePipelineLabel 81 | Should -Be 'agent:shipped'
        (Get-FakeBoardItem 81).status | Should -Be 'Shipped'
        Assert-JourneyClean
    }
}
