#Requires -Version 7.0
<#
    Cli.ps1 — a stand-in for the Claude CLI, for the tables of the engine adapter
    (engines/Claude.ps1), the one file that starts it.

    Everywhere else the fake engine (Engine.ps1) replaces Invoke-EngineTask, so the
    adapter never runs. Here it runs for real: Install-FakeCli defines `claude` as a
    global function, which the adapter's `$Prompt | claude @CliArgs 2>&1` reaches as it
    would reach the CLI. Each start is recorded — the arguments and the piped prompt —
    and replays the next scripted attempt: the lines it prints (event-stream JSON or
    plain text), the exit code it ends with, or a throw for a CLI that cannot start.
    The last attempt repeats. Start-Sleep is mocked in the module's scope, so a retry's
    back-off is recorded rather than waited (Get-FakeCliSleeps).

    Invoke-EngineAtSeam calls Invoke-EngineTask in the module's scope: the adapter is
    the seam the fake engine stands in for, so a table of the adapter enters there.

    Dot-sourced by the tables; no top-level param() (ADR-013).
#>

# A fresh CLI whose starts replay -Attempts: @{ Lines = @(...); Result = @{...}; Exit = 0;
# Throw = '' }. Result is the fields of the result event, printed after the Lines.
function New-FakeCli {
    param([object[]]$Attempts = @(@{ Lines = @(); Exit = 0 }))
    $replay = @(foreach ($a in $Attempts) {
        $lines = @($a.Lines) + @(if ($a.Result) { New-CliResult $a.Result })
        @{ Lines = @($lines | Where-Object { $null -ne $_ }); Exit = [int]$a.Exit; Throw = "$($a.Throw)" }
    })
    $global:FakeCli = @{
        Attempts = $replay
        Calls    = [System.Collections.Generic.List[object]]::new()
        Sleeps   = [System.Collections.Generic.List[int]]::new()
    }
    return $global:FakeCli
}

# Puts the stand-in where the adapter finds `claude`, and records Start-Sleep, for the
# current Pester block. Remove-FakeCli takes the stand-in away again.
function Install-FakeCli {
    function global:claude {
        $prompt = @($input) -join "`n"
        $cli = $global:FakeCli
        $n = $cli.Calls.Count
        $cli.Calls.Add([pscustomobject]@{ Argv = @($args | ForEach-Object { "$_" }); Prompt = $prompt })
        $attempt = $cli.Attempts[[Math]::Min($n, $cli.Attempts.Count - 1)]
        if ($attempt.Throw) { throw $attempt.Throw }
        foreach ($line in @($attempt.Lines)) { $line }
        $global:LASTEXITCODE = [int]$attempt.Exit
    }
    Mock Start-Sleep -ModuleName Orchestrator -MockWith { $global:FakeCli.Sleeps.Add([int]$Seconds) }
}

function Remove-FakeCli {
    Remove-Item -LiteralPath function:global:claude -ErrorAction SilentlyContinue
}

# Every start of the CLI, oldest first: { Argv; Prompt }.
function Get-FakeCliCalls { return @($global:FakeCli.Calls) }

# The seconds each retry's back-off asked to wait.
function Get-FakeCliSleeps { return @($global:FakeCli.Sleeps) }

# The value after -Flag in one start's arguments ($null when the flag is absent).
function Get-FakeCliFlag {
    param([Parameter(Mandatory)]$Call, [Parameter(Mandatory)][string]$Flag)
    $i = [array]::IndexOf([string[]]$Call.Argv, $Flag)
    if ($i -lt 0) { return $null }
    return $Call.Argv[$i + 1]
}

# Calls Invoke-EngineTask, in the module's scope, with -Arguments splatted.
function Invoke-EngineAtSeam {
    param([Parameter(Mandatory)][hashtable]$Arguments)
    return & (Get-Module Orchestrator) { param($a) Invoke-EngineTask @a } $Arguments
}

# ── Event-stream lines, as the CLI prints them ───────────────────────────────

function New-CliResult {
    param([hashtable]$Fields = @{})
    return (@{ type = 'result' } + $Fields | ConvertTo-Json -Depth 8 -Compress)
}

function New-CliAssistant {
    param([object[]]$Blocks)
    return (@{ type = 'assistant'; message = @{ content = @($Blocks) } } | ConvertTo-Json -Depth 8 -Compress)
}

function New-CliToolUse {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$ToolInput = @{})
    return @{ type = 'tool_use'; id = $Name; name = $Name; input = $ToolInput }
}
