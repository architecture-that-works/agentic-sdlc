#Requires -Version 7.0
<#
.SYNOPSIS
    Collects the output of a failing command and an optional source excerpt into a
    single structured Markdown block for agent diagnosis.

.DESCRIPTION
    Runs the given command (via Invoke-Expression), captures its stdout, stderr, and
    exit code, and optionally reads a source file. Writes a single structured Markdown
    block ("## Failure Context") to stdout containing:
      - The command that was run
      - The exit code
      - The full combined output (stdout + stderr)
      - A fenced source excerpt (if -SourceFile is provided)

    The script itself exits 0 regardless of whether the captured command succeeds or
    fails — the captured command's exit code is reported inside the block, not used
    to fail this script.

    Idempotent: re-running with the same inputs produces the same block. No repository
    state is modified.

.PARAMETER Command
    The shell command to run and capture. Passed to Invoke-Expression.
    Example: "uv run pytest tests/test_config.py::test_settings_log_level_default"

.PARAMETER SourceFile
    Optional path to a source file to include as an excerpt in the output block.
    The entire file is included; use -SourceLines to limit the range.

.PARAMETER SourceLines
    Optional line range for -SourceFile, in the form "START-END" (e.g. "25-50").
    Ignored if -SourceFile is not provided.

.EXAMPLE
    # Capture a failing pytest run
    pwsh .agents/skills/diagnosis/scripts/collect-failure-context.ps1 \
        -Command "uv run pytest tests/test_config.py::test_settings_log_level_default" \
        -SourceFile "src/config.py" \
        -SourceLines "25-45"

.EXAMPLE
    # Capture a CI script failure (no source file)
    pwsh .agents/skills/diagnosis/scripts/collect-failure-context.ps1 \
        -Command "pwsh .github/checks/check-module-map.ps1"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Command,

    [string]$SourceFile = '',

    [string]$SourceLines = ''
)

$ErrorActionPreference = 'Stop'

# ── Run the command and capture output ───────────────────────────────────────

$capturedOutput = ''
$capturedExitCode = 0

try {
    # Redirect stderr into stdout so both are captured together
    $capturedOutput = Invoke-Expression "$Command 2>&1" | Out-String
    $capturedExitCode = $LASTEXITCODE
} catch {
    $capturedOutput = $_.Exception.Message
    $capturedExitCode = 1
}

# Normalise: trim trailing whitespace, replace null with empty string
if ($null -eq $capturedOutput) { $capturedOutput = '' }
$capturedOutput = $capturedOutput.TrimEnd()

# ── Read the source file (optional) ─────────────────────────────────────────

$sourceExcerpt = ''
if ($SourceFile -ne '') {
    if (-not (Test-Path $SourceFile)) {
        $sourceExcerpt = "(Source file not found: $SourceFile)"
    } else {
        $allLines = Get-Content $SourceFile

        if ($SourceLines -match '^(\d+)-(\d+)$') {
            $startLine = [int]$Matches[1]
            $endLine   = [int]$Matches[2]
            # Convert to 0-based index
            $startIdx  = [Math]::Max(0, $startLine - 1)
            $endIdx    = [Math]::Min($allLines.Count - 1, $endLine - 1)
            $selectedLines = $allLines[$startIdx..$endIdx]
            $sourceExcerpt = $selectedLines -join "`n"
        } else {
            $sourceExcerpt = $allLines -join "`n"
        }
    }
}

# ── Build the structured Markdown block ──────────────────────────────────────

$timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
$lineRange = if ($SourceLines -ne '') { " (lines $SourceLines)" } else { '' }
$sourceLabel = if ($SourceFile -ne '') { $SourceFile } else { '(none)' }

$block = @"
## Failure Context

**Collected:** $timestamp

**Command:**
``````
$Command
``````

**Exit code:** $capturedExitCode

**Output:**
``````
$capturedOutput
``````
"@

if ($SourceFile -ne '') {
    $block += @"


**Source file:** ``$sourceLabel``$lineRange
``````
$sourceExcerpt
``````
"@
}

Write-Output $block
exit 0
