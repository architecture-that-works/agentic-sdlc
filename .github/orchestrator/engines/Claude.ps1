#Requires -Version 7.0
<#
    Claude.ps1 — generic Claude (LLM) helpers, shared across the orchestrator.

    Provider-generic: streaming agentic invocation with live tool/text rendering,
    and a commit-message generator. Callers pass -Model explicitly (e.g. from
    Get-PhaseModel); the defaults fall back to the tier variables from Config.ps1
    when loaded through the module. Depends only on Write-Log.
#>

# Formats a single tool_use event from Claude's stream for terminal display.
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

# Invoke Claude with streaming JSON output, printing tool use and text to the
# terminal. Returns the full text response as a string. Callers must pass -Model
# (use Get-PhaseModel) and -MaxTurns explicitly.
#
# Retries on a non-zero exit (transient Claude API errors — overloaded 529, rate
# limit, network blips — exit the CLI non-zero after its own internal retries).
# Without this, a single transient blip in a read-only phase (e.g. Review) failed
# the whole issue to agent:failed even though a retry would have succeeded. Throws
# only after $MaxAttempts exhausted.
function Invoke-ClaudeStreaming {
    param(
        [string]$Prompt,
        [string]$AllowedTools = 'Read,Glob,Grep',
        [string]$Label = 'Claude',
        [string]$Model = $KanbanModel_Sonnet,
        [int]$MaxTurns = 30,
        [int]$MaxAttempts = 3
    )

    Write-Log "  ▶ $Label — model=$Model turns=$MaxTurns" -Color DarkGray

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $allText   = [System.Text.StringBuilder]::new()
        $toolCalls = [System.Collections.Generic.List[string]]::new()
        $state     = @{ MaxTurnsReached = $false }

        $Prompt | claude --model $Model --allowedTools $AllowedTools --max-turns $MaxTurns --output-format stream-json --verbose 2>&1 |
        ForEach-Object {
            $raw = [string]$_
            try {
                $ev = $raw | ConvertFrom-Json -ErrorAction Stop

                $blocks = if ($ev.message.content) { $ev.message.content }
                          elseif ($ev.content)      { $ev.content }
                          else                      { @() }

                foreach ($block in $blocks) {
                    switch ($block.type) {
                        'text' {
                            Write-Host $block.text -NoNewline
                            # Append a trailing newline so consecutive text blocks
                            # (separated by tool_use in the stream) are not joined
                            # flush. Without this, downstream regex like
                            # "(?im)^APPROVED" miss verdicts that started a block
                            # because they end up mid-line in $allText.
                            $null = $allText.Append($block.text)
                            $null = $allText.Append("`n")
                        }
                        'tool_use' {
                            $inputReady = ($block.input.PSObject.Properties | Measure-Object).Count -gt 0
                            if ($inputReady) {
                                $line = Format-ToolLine -Name $block.name -ToolInput $block.input
                                Write-Host "`n  $line" -ForegroundColor DarkCyan
                                $toolCalls.Add($line)
                            }
                        }
                    }
                }

                if ($ev.type -eq 'result') {
                    if ($ev.subtype -eq 'error_max_turns') { $state.MaxTurnsReached = $true }
                    Write-Host ''
                }
            } catch {
                if ($raw.Trim()) { Write-Host $raw -ForegroundColor DarkGray }
            }
        }

        if ($state.MaxTurnsReached) { throw "$Label ran out of turns ($MaxTurns)" }

        if ($LASTEXITCODE -eq 0) {
            $summary = if ($allText.Length -gt 0) { ($allText.ToString() -split "`n")[0].Trim() } else { '(no text output)' }
            Write-Log "  ✓ $Label — $($toolCalls.Count) tool call(s). First line: $summary" -Color DarkGray
            return $allText.ToString()
        }

        if ($attempt -lt $MaxAttempts) {
            $backoff = 20 * $attempt
            Write-Log "  ⚠️ $Label exited $LASTEXITCODE (attempt $attempt/$MaxAttempts) — retrying in ${backoff}s (transient API error?)." -Color Yellow
            Start-Sleep -Seconds $backoff
        }
    }

    throw "$Label exited non-zero after $MaxAttempts attempt(s)."
}

# The claude CLI prints a workspace-trust warning to stderr when
# .claude/settings.json carries permissions.allow entries on an untrusted runner.
# Captured via 2>&1 it leaks into parsed output — and as the first line of a
# commit message it became the squash-merge title on main. Strip these known
# non-content lines while preserving real errors.
function Remove-ClaudeNoise {
    param([string]$Text)
    return (($Text -split '\r?\n') | Where-Object {
        $_ -notmatch 'permissions\.allow entries' -and
        $_ -notmatch 'hasTrustDialogAccepted'
    }) -join "`n"
}

# Commit message — Claude primary, fallback to the supplied message.
# Future: add Gemini as secondary between Claude and fallback.
function Get-CommitMessage {
    param([string]$Diff, [string]$FallbackMessage, [string]$Model = $KanbanModel_Aux)

    $prompt = @"
Generate a conventional commit message for the following staged diff.

Rules:
- Format: <type>(<scope>): <description>
- Types: feat, fix, refactor, test, docs, chore, perf, ci, build, revert
- Scope: the module, file, or area changed (omit if not obvious)
- Description: imperative mood, <= 72 chars, no trailing period
- Add a blank line + body only if the change is complex or non-obvious
- Return ONLY the commit message — no explanation, no markdown fences

DIFF:
$Diff
"@

    $msg = Remove-ClaudeNoise -Text ($prompt | claude --model $Model 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $msg.Trim()) {
        Write-Log "  Commit message via Claude." -Color DarkGray
        return $msg.Trim()
    }

    Write-Log "  Claude unavailable — using issue title fallback." -Color Yellow
    return $FallbackMessage
}
