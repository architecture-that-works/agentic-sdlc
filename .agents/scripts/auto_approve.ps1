$inputJson = $input | Out-String | ConvertFrom-Json
if (-not $inputJson -or -not $inputJson.toolCall -or -not $inputJson.toolCall.args.CommandLine) {
    '{"decision": "ask", "reason": "No CommandLine provided"}'
    exit 0
}

$cmdLine = $inputJson.toolCall.args.CommandLine.Trim()
$parts = -split $cmdLine
$firstWord = $parts[0]

$allowed = @("git", "uv", "pytest", "ruff", "pyright", "gh")

if ($allowed -contains $firstWord) {
    '{"decision": "allow", "reason": "Auto-approved configured command"}'
} else {
    '{"decision": "ask", "reason": "Requires user confirmation"}'
}
