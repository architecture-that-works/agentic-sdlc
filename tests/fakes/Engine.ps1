#Requires -Version 7.0
<#
    Engine.ps1 — the one fake engine for the orchestrator's journeys.

    Invoke-EngineTask is the one function in the orchestrator that starts a model
    (engines/Claude.ps1). Install-FakeEngine mocks it in the Orchestrator module's
    scope, so every model call — the EngineCheck ping behind the readiness check
    included — gets what the test scripted instead. The Engine setting is not touched.

    A test scripts each Task (EngineCheck, Refine, Plan, ImplementLarge,
    ImplementSmall, Review, CommitMessage) as a queue of results with Add-EngineResult:
    an Outcome, a Reply, the Output, a checked Answer (for a call with -Schema — the
    implement tasks' closing note and the review's verdict; a call with -Schema that
    finishes without one fails, as the engine adapter's does), the
    RefusedEdits, and for an implement task the Edits it makes to the working tree
    and the ToolCalls it reports while it runs. -During is what happens elsewhere
    while that call runs — the owner merging the pull request by hand, say — run once
    the Edits are made. Each call takes the next result of
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
        Invoke-FakeEngineTask -Task $Task -Prompt $Prompt -Label $Label -Tools $Tools -MaxTurns $MaxTurns -Schema $Schema -OnToolCall $OnToolCall
    }
}

# What the engine prints when the usage allowance is spent, taken from the wording the
# engine adapter recognises ($KanbanUsageLimitPattern, engines/) — never restated here.
# -ResetsAt adds the reset time the way the CLI reports it (an epoch after '|').
# Script it as an EngineCheck -Output: the readiness check then reads a spent allowance.
function Get-EngineUsageLimitText {
    param([datetime]$ResetsAt)
    $pattern = & (Get-Module Orchestrator) { $KanbanUsageLimitPattern }
    $wording = (($pattern -replace '^\(\?i\)', '') -split '\|')[0]
    if ($wording -notmatch $pattern -or $wording -match '[\\\[\](){}?*+^$]') {
        throw "Get-EngineUsageLimitText: the adapter's first usage-limit wording '$wording' is not plain text."
    }
    $text = "Claude $wording"
    if ($PSBoundParameters.ContainsKey('ResetsAt')) {
        $text += "|$([DateTimeOffset]::new($ResetsAt.ToUniversalTime()).ToUnixTimeSeconds())"
    }
    return $text
}

# One scripted result for -Task, queued behind those already scripted for it.
#   -Edits      @{ '<repo-relative path>' = '<content>' } written to the working tree
#               ($null content deletes the file)
#   -ToolCalls  @(@{ Name = 'Write'; Input = @{ file_path = '...' } }, ...) reported
#               to the caller's -OnToolCall while the run goes
#   -During     { ... } run while the call is going, after the Edits: what someone
#               else does meanwhile, through the fakes' own helpers and the module's
#               exported entry points
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
        [object[]]$ToolCalls = @(),
        [scriptblock]$During = $null
    )
    if (-not $global:FakeEngine.Queues.ContainsKey($Task)) {
        $global:FakeEngine.Queues[$Task] = [System.Collections.Generic.Queue[object]]::new()
    }
    $global:FakeEngine.Queues[$Task].Enqueue([pscustomobject]@{
        Outcome = $Outcome; Reply = $Reply; Output = $Output; Answer = $Answer
        RefusedEdits = $RefusedEdits; Edits = $Edits; ToolCalls = $ToolCalls; During = $During
    })
}

# The calls the engine received, oldest first: { Task; Label; Prompt; Tools; MaxTurns; Schema }.
# MaxTurns is the turn budget an agentic call passed (0 for a one-shot call).
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
    param([string]$Task, [string]$Prompt, [string]$Label, [string[]]$Tools, [int]$MaxTurns, [string]$Schema, [scriptblock]$OnToolCall)
    $engine = $global:FakeEngine
    if (-not $engine) { throw "The fake engine is not set up (New-FakeEngine) — Task '$Task'" }
    $engine.Calls.Add([pscustomobject]@{ Task = $Task; Label = $Label; Prompt = $Prompt; Tools = @($Tools | Where-Object { $_ }); MaxTurns = $MaxTurns; Schema = $Schema })

    $queue = $engine.Queues[$Task]
    if ($queue -and $queue.Count -gt 0) {
        $result = $queue.Dequeue()
    } elseif ($Task -eq 'EngineCheck') {
        $result = [pscustomobject]@{ Outcome = 'finished'; Reply = 'pong'; Output = ''; Answer = $null; RefusedEdits = @(); Edits = @{}; ToolCalls = @(); During = $null }
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
    if ($result.During) { $null = & $result.During }
    $called = [System.Collections.Generic.List[string]]::new()
    foreach ($call in @($result.ToolCalls | Where-Object { $_ })) {
        $called.Add("$($call.Name)")
        if ($OnToolCall) { $null = & $OnToolCall ([pscustomobject]@{ Name = "$($call.Name)"; Input = [pscustomobject]$call.Input }) }
    }

    # A call with -Schema that finishes without a scripted Answer fails, as the engine
    # adapter fails a run whose result holds no checked answer.
    $outcome = $result.Outcome
    $cause   = if ($outcome -eq 'max_turns') { "$Label ran out of turns" } elseif ($outcome -ne 'finished') { "$Label failed (scripted)" } else { $null }
    if ($Schema -and $outcome -eq 'finished' -and $null -eq $result.Answer) {
        $outcome = 'failed'
        $cause   = "$Label produced no checked answer: the result holds no structured_output"
    }
    $finished = $outcome -eq 'finished'
    return [pscustomobject]@{
        Reply        = $result.Reply
        ToolsCalled  = $called.ToArray()
        Outcome      = $outcome
        RefusedEdits = @($result.RefusedEdits)
        Answer       = if ($Schema -and $finished) { $result.Answer } else { $null }
        Output       = $result.Output
        Cause        = $cause
    }
}
