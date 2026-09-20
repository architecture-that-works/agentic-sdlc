#Requires -Version 7.0
<#
    Gemini.ps1 — generic Gemini (LLM) helpers, shared across .github/scripts.

    Provider-generic: streaming agentic invocation with live tool/text rendering,
    and a commit-message generator. NOT kanban-specific — callers pass -Model
    (e.g. from the kanban Get-PhaseModel selector). Depends only on Write-Log.
#>

# Formats a single tool_use event from Gemini's stream for terminal display.
function Format-GeminiToolLine {
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

# Invoke Gemini with streaming JSON output, printing tool use and text to the
# terminal. Returns the full text response as a string. Callers must pass -Model
# (use Get-PhaseModel) and -MaxTurns explicitly.
function Invoke-GeminiStreaming {
    param(
        [string]$Prompt,
        [string]$AllowedTools = 'Read,Glob,Grep',
        [string]$Label = 'Gemini',
        [string]$Model = 'gemini-3.5-flash',
        [int]$MaxTurns = 30,
        [int]$MaxAttempts = 3
    )

    Write-Log "  ▶ $Label — model=$Model turns=$MaxTurns" -Color DarkGray

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $allText   = [System.Text.StringBuilder]::new()
        $toolCalls = [System.Collections.Generic.List[string]]::new()

        # Assuming agy accepts similar flags for headless stream JSON processing
        $Prompt | agy --model $Model --allowedTools $AllowedTools --max-turns $MaxTurns --output-format stream-json --verbose 2>&1 |
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
                            $null = $allText.Append($block.text)
                            $null = $allText.Append("`n")
                        }
                        'tool_use' {
                            $inputReady = ($block.input.PSObject.Properties | Measure-Object).Count -gt 0
                            if ($inputReady) {
                                $line = Format-GeminiToolLine -Name $block.name -ToolInput $block.input
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

function Remove-GeminiNoise {
    param([string]$Text)
    return (($Text -split '\r?\n') | Where-Object {
        $_ -notmatch 'permissions\.allow entries' -and
        $_ -notmatch 'hasTrustDialogAccepted'
    }) -join "`n"
}

# Commit message — Gemini primary, fallback to the supplied message.
function Get-GeminiCommitMessage {
    param([string]$Diff, [string]$FallbackMessage, [string]$Model = 'gemini-3.5-flash')

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

    $msg = Remove-GeminiNoise -Text ($prompt | agy --model $Model 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $msg.Trim()) {
        Write-Log "  Commit message via Gemini." -Color DarkGray
        return $msg.Trim()
    }

    Write-Log "  Gemini unavailable — using issue title fallback." -Color Yellow
    return $FallbackMessage
}
