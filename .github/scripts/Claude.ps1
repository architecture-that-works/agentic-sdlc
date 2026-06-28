#Requires -Version 7.0
<#
    Claude.ps1 — generic Claude (LLM) helpers, shared across .github/scripts.

    Provider-generic: streaming agentic invocation with live tool/text rendering,
    and a commit-message generator. NOT kanban-specific — callers pass -Model
    (e.g. from the kanban Get-PhaseModel selector); the defaults below are plain
    fallbacks with no $Kanban* coupling. Depends only on Write-Log.
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
# terminal. Returns the full text response as a string. Throws if Claude exits
# non-zero. Callers must pass -Model (use Get-PhaseModel) and -MaxTurns explicitly.
function Invoke-ClaudeStreaming {
    param(
        [string]$Prompt,
        [string]$AllowedTools = 'Read,Glob,Grep',
        [string]$Label = 'Claude',
        [string]$Model = 'claude-sonnet-4-6',
        [int]$MaxTurns = 30
    )

    Write-Log "  ▶ $Label — model=$Model turns=$MaxTurns" -Color DarkGray

    $allText    = [System.Text.StringBuilder]::new()
    $toolCalls  = [System.Collections.Generic.List[string]]::new()

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

            if ($ev.type -eq 'result') { Write-Host '' }
        } catch {
            if ($raw.Trim()) { Write-Host $raw -ForegroundColor DarkGray }
        }
    }

    if ($LASTEXITCODE -ne 0) { throw "$Label exited with code $LASTEXITCODE." }

    $summary = if ($allText.Length -gt 0) { ($allText.ToString() -split "`n")[0].Trim() } else { '(no text output)' }
    Write-Log "  ✓ $Label — $($toolCalls.Count) tool call(s). First line: $summary" -Color DarkGray

    return $allText.ToString()
}

# Commit message — Claude primary, fallback to the supplied message.
# Future: add Gemini as secondary between Claude and fallback.
function Get-CommitMessage {
    param([string]$Diff, [string]$FallbackMessage, [string]$Model = 'claude-haiku-4-5-20251001')

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

    $msg = $prompt | claude --model $Model 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $msg.Trim()) {
        Write-Log "  Commit message via Claude." -Color DarkGray
        return $msg.Trim()
    }

    Write-Log "  Claude unavailable — using issue title fallback." -Color Yellow
    return $FallbackMessage
}
