#Requires -Version 7.0
<#
    Engine.ps1 — the one fake engine for the orchestrator's journeys.

    Invoke-EngineTask is the one function in the orchestrator that starts a model
    (engines/Claude.ps1). Install-FakeEngine mocks it in the Orchestrator module's
    scope, so every model call — the EngineCheck ping behind the readiness check
    included — gets what the test scripted instead. The Engine setting is not touched.

    A test scripts each Task (EngineCheck, Refine, Plan, ImplementLarge,
    ImplementSmall, Review, CommitMessage) as a queue of results with Add-EngineResult:
    an Outcome, a Reply, the Output, a checked Answer (for a call with -Schema), the
    RefusedEdits, and for an implement task the Edits it makes to the working tree
    and the ToolCalls it reports while it runs. Each call takes the next result of
    its Task. A Task with nothing scripted fails the test and names the Task —
    except EngineCheck, which answers 'pong' (the engine is ready) unless scripted.

    Dot-sourced by the journeys; no top-level param() (ADR-013).
#>

# A fresh engine with nothing scripted.
function New-FakeEngine {
    $global:FakeEngine = @{
        Queues  = @{}
        Calls   = [System.Collections.Generic.List[object]]::new()
        Unknown = [System.Collections.Generic.List[string]]::new()
    }
    return $global:FakeEngine
}

# Mocks Invoke-EngineTask in the Orchestrator module's scope for the current Pester block.
function Install-FakeEngine {
    Mock Invoke-EngineTask -ModuleName Orchestrator -MockWith {
        Invoke-FakeEngineTask -Task $Task -Prompt $Prompt -Label $Label -Tools $Tools -Schema $Schema -OnToolCall $OnToolCall
    }
}

# One scripted result for -Task, queued behind those already scripted for it.
#   -Edits      @{ '<repo-relative path>' = '<content>' } written to the working tree
#               ($null content deletes the file)
#   -ToolCalls  @(@{ Name = 'Write'; Input = @{ file_path = '...' } }, ...) reported
#               to the caller's -OnToolCall while the run goes
function Add-EngineResult {
    param(
        [Parameter(Mandatory)][ValidateSet('EngineCheck', 'Refine', 'Plan', 'ImplementLarge', 'ImplementSmall', 'Review', 'CommitMessage')]
        [string]$Task,
        [ValidateSet('finished', 'max_turns', 'failed')][string]$Outcome = 'finished',
        [string]$Reply = '',
        [string]$Output = '',
        $Answer = $null,
        [string[]]$RefusedEdits = @(),
        [hashtable]$Edits = @{},
        [object[]]$ToolCalls = @()
    )
    if (-not $global:FakeEngine.Queues.ContainsKey($Task)) {
        $global:FakeEngine.Queues[$Task] = [System.Collections.Generic.Queue[object]]::new()
    }
    $global:FakeEngine.Queues[$Task].Enqueue([pscustomobject]@{
        Outcome = $Outcome; Reply = $Reply; Output = $Output; Answer = $Answer
        RefusedEdits = $RefusedEdits; Edits = $Edits; ToolCalls = $ToolCalls
    })
}

# The calls the engine received, oldest first: { Task; Label; Prompt; Tools; Schema }.
function Get-FakeEngineCalls {
    param([string]$Task = '')
    return @($global:FakeEngine.Calls | Where-Object { -not $Task -or $_.Task -eq $Task })
}

# Throws when a Task was called with nothing scripted, or a scripted result was never used.
function Assert-FakeEngineClean {
    $problems = @($global:FakeEngine.Unknown)
    foreach ($task in $global:FakeEngine.Queues.Keys) {
        $left = $global:FakeEngine.Queues[$task].Count
        if ($left -gt 0) { $problems += "Task '$task': $left scripted result(s) never used" }
    }
    if ($problems.Count -gt 0) { throw "The fake engine:`n$($problems -join "`n")" }
}

function Invoke-FakeEngineTask {
    param([string]$Task, [string]$Prompt, [string]$Label, [string[]]$Tools, [string]$Schema, [scriptblock]$OnToolCall)
    $engine = $global:FakeEngine
    if (-not $engine) { throw "The fake engine is not set up (New-FakeEngine) — Task '$Task'" }
    $engine.Calls.Add([pscustomobject]@{ Task = $Task; Label = $Label; Prompt = $Prompt; Tools = @($Tools); Schema = $Schema })

    $queue = $engine.Queues[$Task]
    if ($queue -and $queue.Count -gt 0) {
        $result = $queue.Dequeue()
    } elseif ($Task -eq 'EngineCheck') {
        $result = [pscustomobject]@{ Outcome = 'finished'; Reply = 'pong'; Output = ''; Answer = $null; RefusedEdits = @(); Edits = @{}; ToolCalls = @() }
    } else {
        $message = "The fake engine has nothing scripted for Task '$Task' ($Label)."
        $engine.Unknown.Add($message)
        throw $message
    }

    foreach ($path in $result.Edits.Keys) {
        $full = Join-Path (Get-Location).ProviderPath $path
        if ($null -eq $result.Edits[$path]) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue; continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
        Set-Content -LiteralPath $full -Value $result.Edits[$path] -Encoding utf8NoBOM -NoNewline
    }
    $called = [System.Collections.Generic.List[string]]::new()
    foreach ($call in @($result.ToolCalls | Where-Object { $_ })) {
        $called.Add("$($call.Name)")
        if ($OnToolCall) { $null = & $OnToolCall ([pscustomobject]@{ Name = "$($call.Name)"; Input = [pscustomobject]$call.Input }) }
    }

    $finished = $result.Outcome -eq 'finished'
    return [pscustomobject]@{
        Reply        = $result.Reply
        ToolsCalled  = $called.ToArray()
        Outcome      = $result.Outcome
        RefusedEdits = @($result.RefusedEdits)
        Answer       = if ($Schema -and $finished) { $result.Answer } else { $null }
        Output       = $result.Output
        Cause        = if ($finished) { $null } elseif ($result.Outcome -eq 'max_turns') { "$Label ran out of turns" } else { "$Label failed (scripted)" }
    }
}
