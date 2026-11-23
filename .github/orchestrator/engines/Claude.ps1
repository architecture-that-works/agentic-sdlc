#Requires -Version 7.0
<#
    Claude.ps1 — the Claude engine adapter. The one file that knows the Claude CLI.

    Invoke-EngineTask is the only function in the orchestrator that starts a model:
    every stage calls it with a task name and a prompt, never with a model or a CLI
    flag. It builds the CLI's arguments, reads its event stream and returns one
    engine-neutral object (see below). The commit-message generator and the
    usage-limit wording also live here, since both are about this engine.

    A further engine adds its own adapter in engines/ with the same functions; the
    module loads the adapter the Engine setting names (Orchestrator.psm1).
    Depends only on Write-Log and Get-TaskModel.
#>

# How this engine words a spent usage allowance (#229). Spend and session limits
# are how Claude words a spent subscription allowance; "hit your … limit" allows a
# few words between ("hit your org's monthly spend limit", "hit your daily limit")
# but stays inside one sentence, so an unrelated "hit your" and a later "limit" in a
# long error log never pair up. The one definition: Invoke-EngineTask uses it not to
# retry such a call, and the readiness check (Get-UsageLimitResume, lib/Util.ps1)
# uses it to pause the issue.
$KanbanUsageLimitPattern = '(?i)usage limit|limit reached|rate_limit_error|hit your\b[^.·\n]{0,40}?\blimit|spend limit|session limit'

# Attempts for a call that fails on a non-zero exit (transient API errors —
# overloaded 529, rate limit, network blips — exit the CLI non-zero after its own
# internal retries), with 20s × attempt between them.
$EngineTaskMaxAttempts = 3

# Formats a single tool call for terminal display.
function Format-ToolLine {
    param([string]$Name, $ToolInput)
    switch ($Name) {
        'Read'  { "📖 Read:  $($ToolInput.file_path)" }
        'Write' { "✏️  Write: $($ToolInput.file_path)" }
        'Edit'  { "✏️  Edit:  $($ToolInput.file_path)" }
        'Glob'  { "🔍 Glob:  $($ToolInput.pattern)" }
        'Grep'  { "🔍 Grep:  $($ToolInput.pattern)" }
        'Bash'  { "⚡ Bash:  $([string]$ToolInput.command -replace '\r?\n.*','' -replace '\s+',' ')" }
        default { "🔧 $Name" }
    }
}

# The CLI prints a workspace-trust warning to stderr when .claude/settings.json
# carries permissions.allow entries on an untrusted runner. Captured via 2>&1 it
# leaks into the output — and as the first line of a commit message it once became
# the squash-merge title on main. These known non-content lines are dropped; real
# errors are kept.
function Test-EngineNoiseLine {
    param([string]$Line)
    return ($Line -match 'permissions\.allow entries' -or $Line -match 'hasTrustDialogAccepted')
}

# Pure: the repo-relative paths of the file edits the engine refused (#346), unique
# and in order. Read only from what the engine reports — the permission_denials[] of
# its result event — never from the agent's prose. A denied tool that edits no file
# (a Bash command) is not an edit refusal. Claude Code refuses writes to its
# protected paths (.devcontainer/, .claude/, ...) in an unattended run whatever the
# allow rules say, so a retry cannot help.
function Get-RefusedEdits {
    param($ResultEvent, [string]$RepoRoot = '')
    if (-not $ResultEvent -or -not $ResultEvent.PSObject.Properties['permission_denials']) { return @() }

    $root  = "$RepoRoot".Replace('\', '/').TrimEnd('/')
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($d in @($ResultEvent.permission_denials | Where-Object { $_ })) {
        if ("$($d.tool_name)" -notin @('Write', 'Edit', 'NotebookEdit')) { continue }
        $fp = "$($d.tool_input.file_path)"
        if (-not $fp) { $fp = "$($d.tool_input.notebook_path)" }
        if (-not $fp) { continue }
        $fp = $fp.Replace('\', '/')
        if ($root -and [System.IO.Path]::IsPathRooted($fp)) {
            $rel = [System.IO.Path]::GetRelativePath($root, $fp).Replace('\', '/')
            if (-not $rel.StartsWith('..')) { $fp = $rel }
        }
        $fp = $fp -replace '^\./', ''
        if (-not $paths.Contains($fp)) { $paths.Add($fp) }
    }
    return $paths.ToArray()
}

# One run of the CLI: starts it, reads its event stream line by line, renders the
# tool calls and text, and calls -OnToolCall for each tool call as it streams.
function Invoke-EngineRun {
    param([string]$Prompt, [string[]]$CliArgs, [scriptblock]$OnToolCall)

    $tools  = [System.Collections.Generic.List[string]]::new()
    $output = [System.Collections.Generic.List[string]]::new()
    $state  = @{ Result = $null; Exit = 0; Thrown = $null }

    try {
        $global:LASTEXITCODE = 0
        $Prompt | claude @CliArgs 2>&1 | ForEach-Object {
            $raw = [string]$_
            if (Test-EngineNoiseLine -Line $raw) { return }
            $ev = $null
            if ($raw -match '^\s*\{') {
                try { $ev = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $ev = $null }
            }
            if ($null -eq $ev) {
                if ($raw.Trim()) {
                    Write-Host $raw -ForegroundColor DarkGray
                    $output.Add($raw)
                }
                return
            }

            $blocks = if ($ev.PSObject.Properties['message'] -and $ev.message.content) { $ev.message.content }
                      elseif ($ev.PSObject.Properties['content'] -and $ev.content) { $ev.content }
                      else { @() }
            foreach ($block in @($blocks | Where-Object { $_ })) {
                switch ($block.type) {
                    'text' { Write-Host $block.text -NoNewline }
                    'tool_use' {
                        # StructuredOutput is how the engine returns a checked answer —
                        # not a tool the agent chose: neither shown, counted nor reported.
                        if ($block.name -eq 'StructuredOutput') { break }
                        $tools.Add([string]$block.name)
                        if ($block.input -and ($block.input.PSObject.Properties | Measure-Object).Count -gt 0) {
                            Write-Host "`n  $(Format-ToolLine -Name $block.name -ToolInput $block.input)" -ForegroundColor DarkCyan
                        }
                        if ($OnToolCall) {
                            # Whatever the callback writes is not the run's output.
                            $null = & $OnToolCall ([pscustomobject]@{ Name = [string]$block.name; Input = $block.input })
                        }
                    }
                }
            }
            if ($ev.type -eq 'result') {
                $state.Result = $ev
                Write-Host ''
            }
        } | Out-Null
        $state.Exit = $LASTEXITCODE
    } catch {
        # A CLI that cannot start at all (not installed, crashed in the shell).
        $state.Thrown = "$($_.Exception.Message)"
        $state.Exit   = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
    }

    return [pscustomobject]@{
        Result = $state.Result
        Exit   = $state.Exit
        Thrown = $state.Thrown
        Tools  = $tools.ToArray()
        Output = ($output -join "`n")
    }
}

# Invoke-EngineTask — the one function that starts a model.
#
#   -Task      a TaskTiers key; the model is Get-TaskModel's answer for it, on the
#              Engine setting. A caller never passes a model or a CLI flag.
#   -Prompt    the prompt, piped to the CLI.
#   -Label     the name the run is logged under.
#   -Tools     agentic work: the tool set, used both as the tools that exist and as
#              the tools that are pre-approved. Comes with -MaxTurns; a one-shot call
#              passes neither and runs with no tools at all.
#   -MaxTurns  agentic work: the turn budget.
#   -Schema    a checked answer: JSON Schema draft-07 text; the answer comes back in
#              Answer.
#   -OnToolCall  called once per tool call as it streams, with { Name; Input }.
#
# Returns { Reply; ToolsCalled; Outcome; RefusedEdits; Answer; Output; Cause }:
#   Reply         the result event's final text
#   ToolsCalled   tool names in call order, without the engine's StructuredOutput
#   Outcome       'finished' | 'max_turns' | 'failed'
#   RefusedEdits  repo-relative paths of the Write/Edit/NotebookEdit calls refused
#   Answer        the checked answer when -Schema was passed, else $null
#   Output        the non-event text the CLI printed, noise stripped
#   Cause         why a failed run failed, else $null
#
# It never throws for a failed run; each caller decides what a failed run or a
# used-up turn budget means for its stage. A run that ends on its turn budget, a run
# without a checked answer, a CLI that cannot start and a spent usage allowance are
# not retried. Any other non-zero exit is retried up to $EngineTaskMaxAttempts
# attempts, 20s × attempt apart.
function Invoke-EngineTask {
    param(
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Label,
        [string[]]$Tools,
        [int]$MaxTurns,
        [string]$Schema,
        [scriptblock]$OnToolCall
    )

    $agentic = $PSBoundParameters.ContainsKey('Tools')
    if ($agentic -ne $PSBoundParameters.ContainsKey('MaxTurns')) {
        throw "Invoke-EngineTask ($Label): -Tools and -MaxTurns come together — an agentic call passes both, a one-shot call neither."
    }
    if ($agentic -and $MaxTurns -le 0) {
        throw "Invoke-EngineTask ($Label): -MaxTurns must be a positive turn budget, got $MaxTurns."
    }

    $model    = Get-TaskModel -Task $Task
    $toolList = (@($Tools | Where-Object { $_ }) -join ',')

    # Every flag the CLI is started with is written here, and only here.
    $cliArgs = @('-p', '--model', $model, '--tools', $toolList)
    if ($agentic) { $cliArgs += @('--allowedTools', $toolList, '--max-turns', "$MaxTurns") }
    if ($Schema)  { $cliArgs += @('--json-schema', $Schema) }
    $cliArgs += @('--output-format', 'stream-json', '--verbose')

    $budget = if ($agentic) { "turns=$MaxTurns tools=$(if ($toolList) { $toolList } else { 'none' })" } else { 'one-shot' }
    Write-Log "  ▶ $Label — model=$model $budget" -Color DarkGray

    $repoRoot = "$((Get-Location).ProviderPath)"
    $run      = $null
    $outcome  = 'failed'
    $cause    = $null

    for ($attempt = 1; $attempt -le $EngineTaskMaxAttempts; $attempt++) {
        $run    = Invoke-EngineRun -Prompt $Prompt -CliArgs $cliArgs -OnToolCall $OnToolCall
        $result = $run.Result
        $text   = "$($run.Output)`n$(if ($result) { $result.result })"

        if ($run.Thrown) {
            $outcome = 'failed'; $cause = "the engine CLI could not run: $($run.Thrown)"; break
        }
        if ($result -and $result.subtype -eq 'error_max_turns') {
            $outcome = 'max_turns'; $cause = "$Label ran out of turns ($MaxTurns)"; break
        }
        if ($Schema -and $result -and $result.subtype -eq 'error_max_structured_output_retries') {
            $outcome = 'failed'; $cause = "$Label produced no checked answer: error_max_structured_output_retries"; break
        }
        $succeeded = $result -and $result.subtype -eq 'success' -and -not $result.is_error
        if ($succeeded) {
            if ($Schema -and $null -eq $result.structured_output) {
                $outcome = 'failed'; $cause = "$Label produced no checked answer: the result holds no structured_output"; break
            }
            $outcome = 'finished'; $cause = $null; break
        }
        if ($text -match $KanbanUsageLimitPattern) {
            $outcome = 'failed'; $cause = "$Label hit the engine's usage limit: $($text.Trim())"; break
        }
        if ($run.Exit -eq 0) {
            $why = if ($result) { "the run ended with '$($result.subtype)'" } else { 'the engine gave no result' }
            $outcome = 'failed'; $cause = "${Label}: $why"; break
        }

        $outcome = 'failed'
        $cause   = "$Label exited $($run.Exit) after $attempt attempt(s)."
        if ($attempt -lt $EngineTaskMaxAttempts) {
            $backoff = 20 * $attempt
            Write-Log "  ⚠️ $Label exited $($run.Exit) (attempt $attempt/$EngineTaskMaxAttempts) — retrying in ${backoff}s (transient API error?)." -Color Yellow
            Start-Sleep -Seconds $backoff
        }
    }

    $result = $run.Result
    $toolsCalled = @($run.Tools)
    if ($outcome -eq 'finished') {
        Write-Log "  ✓ $Label — $($toolsCalled.Count) tool call(s)." -Color DarkGray
    } else {
        Write-Log "  ✗ $Label — $outcome$(if ($cause) { ": $cause" })" -Color Yellow
    }

    return [pscustomobject]@{
        Reply        = if ($result -and $null -ne $result.result) { "$($result.result)" } else { '' }
        ToolsCalled  = $toolsCalled
        Outcome      = $outcome
        RefusedEdits = @(Get-RefusedEdits -ResultEvent $result -RepoRoot $repoRoot)
        Answer       = if ($Schema -and $outcome -eq 'finished') { $result.structured_output } else { $null }
        Output       = $run.Output
        Cause        = $cause
    }
}

# ── Commit message ────────────────────────────────────────────────────────────
#
# The rules of a commit message, written once (#417). The generator's prompt states
# them, every reply is checked against them, and the fallback meets them too. A pull
# request's title is the first line of the message, and a squash merge puts it on the
# default branch with " (#<pr>)" behind it; the limit is on the title.
#   Name   what a broken rule is called in a log
#   Text   the rule as the prompt states it; {0} is the caller's issue number
#   Broken { param($FirstLine, $Message, $Number) } — $true when the rule is broken
$CommitMessageTypes   = @('feat', 'fix', 'refactor', 'test', 'docs', 'chore', 'perf', 'ci', 'build', 'revert')
$CommitFirstLineLimit = 72
$CommitTrailerPattern = '(?im)^\s*(Co-Authored-By|Signed-off-by)\s*:'
$CommitMessageRules   = @(
    @{ Name = 'format'
       Text = "The first line is ``<type>(#{0}): <description>`` — <type> is one of $($CommitMessageTypes -join ', '); the scope is the issue number #{0}; the description is in the imperative mood."
       Broken = { param($FirstLine, $Message, $Number) $FirstLine -cnotmatch "^($($CommitMessageTypes -join '|'))\(#$Number\): \S" } }
    @{ Name = 'length'
       Text = "The whole first line is at most $CommitFirstLineLimit characters."
       Broken = { param($FirstLine, $Message, $Number) $FirstLine.Length -gt $CommitFirstLineLimit } }
    @{ Name = 'period'
       Text = 'The first line does not end with a period.'
       Broken = { param($FirstLine, $Message, $Number) $FirstLine.EndsWith('.') } }
    @{ Name = 'fence'
       Text = 'The message holds no markdown fence (```) — it is the message alone, with no explanation around it.'
       Broken = { param($FirstLine, $Message, $Number) $Message.Contains('```') } }
    @{ Name = 'trailer'
       Text = 'The message holds no Co-Authored-By or Signed-off-by trailer.'
       Broken = { param($FirstLine, $Message, $Number) $Message -match $CommitTrailerPattern } }
)

# Pure: the first rule -Message breaks, as { Name; Text } with the number filled in,
# or $null when it meets every rule.
function Get-CommitRuleBroken {
    param([AllowEmptyString()][string]$Message, [Parameter(Mandatory)][int]$Number)
    $first = @("$Message" -split '\r?\n')[0]
    foreach ($rule in $CommitMessageRules) {
        if (& $rule.Broken $first "$Message" $Number) {
            return [pscustomobject]@{ Name = $rule.Name; Text = ($rule.Text -f $Number) }
        }
    }
    return $null
}

# Pure: -Message without its Co-Authored-By and Signed-off-by lines, trimmed.
function Remove-CommitTrailers {
    param([AllowEmptyString()][string]$Message)
    $lines = @("$Message" -split '\r?\n' | Where-Object { $_ -notmatch $CommitTrailerPattern })
    return ($lines -join "`n").Trim()
}

# Pure: the message used when the engine gives none — `feat(#<Number>): <Title>`,
# the title cut at the last word boundary that keeps the line within the limit, with
# trailing spaces and periods removed. It meets every rule.
function Get-CommitFallback {
    param([Parameter(Mandatory)][int]$Number, [AllowEmptyString()][string]$Title)
    $prefix = "feat(#${Number}): "
    $room   = $CommitFirstLineLimit - $prefix.Length
    $text   = (("$Title" -replace '```', '') -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ($text.Length -gt $room) {
        $cut  = $text.Substring(0, $room + 1)
        $last = $cut.LastIndexOf(' ')
        $text = if ($last -gt 0) { $cut.Substring(0, $last) } else { $text.Substring(0, $room) }
        $text = $text.TrimEnd('.', ' ')
    }
    if (-not $text) { $text = "implement issue #$Number" }
    return "$prefix$text"
}

# Commit message — the engine first, checked against the rules; asked once more,
# naming the broken rule, when a reply breaks one; the fallback otherwise.
# Returns { Message; FromEngine } — FromEngine says whether the engine wrote it.
function Get-CommitMessage {
    param(
        [AllowEmptyString()][string]$Diff,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title
    )

    $rules  = ($CommitMessageRules | ForEach-Object { "- $($_.Text -f $Number)" }) -join "`n"
    $prompt = @"
Generate a conventional commit message for the following staged diff of issue #$Number.

Rules:
$rules
- Add a blank line + body only if the change is complex or non-obvious.
- Return ONLY the commit message.

DIFF:
$Diff
"@

    $ask = $prompt
    for ($round = 1; $round -le 2; $round++) {
        $run = Invoke-EngineTask -Task 'CommitMessage' -Prompt $ask -Label 'Commit message'
        if ($run.Outcome -ne 'finished' -or -not "$($run.Reply)".Trim()) {
            Write-Log "  Engine gave no commit message — using the issue title fallback." -Color Yellow
            break
        }
        $message = Remove-CommitTrailers -Message $run.Reply
        $broken  = Get-CommitRuleBroken -Message $message -Number $Number
        if (-not $broken) {
            Write-Log "  Commit message via the engine." -Color DarkGray
            return [pscustomobject]@{ Message = $message; FromEngine = $true }
        }
        Write-Log "  Commit message breaks the rule '$($broken.Name)' (reply $round of 2)." -Color Yellow
        $ask = @"
$prompt

Your previous reply broke this rule: $($broken.Text)
Your previous reply was:
$message

Write the commit message again, meeting every rule.
"@
    }

    return [pscustomobject]@{ Message = (Get-CommitFallback -Number $Number -Title $Title); FromEngine = $false }
}
