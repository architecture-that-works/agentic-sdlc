#Requires -Version 7.0
<#
.SYNOPSIS
    Guards the settings table: every key of $OrchestratorConfig (.github/orchestrator/
    lib/Config.ps1) is read by the orchestrator or a Command.

.DESCRIPTION
    $OrchestratorConfig is the one place every orchestrator setting has its value. A key
    nothing reads is a setting that changes nothing: whoever edits it believes they
    changed the pipeline. A read is `$OrchestratorConfig.<Key>` or
    `$OrchestratorConfig['<Key>']` in a .ps1 or .psm1 under .github/orchestrator/ or
    .github/tasks/, found with PowerShell's own parser — so a comment, the `Key = ...`
    line of the table and a property of another object (`$ctx.Engine`) do not count.

    Exits 0 when every key is read; exits 1 naming each key nothing reads.

.EXAMPLE
    pwsh .github/checks/check-settings-read.ps1
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath
$Config   = Join-Path $RepoRoot '.github/orchestrator/lib/Config.ps1'

function Read-Ast([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Cannot parse ${Path}: $($errors[0].Message)" }
    return $ast
}

function Test-TableVariable($Ast) {
    $Ast -is [System.Management.Automation.Language.VariableExpressionAst] -and
        ($Ast.VariablePath.UserPath -replace '^\w+:', '') -eq 'OrchestratorConfig'
}

if (-not (Test-Path -LiteralPath $Config)) {
    Write-Host '❌ .github/orchestrator/lib/Config.ps1 is missing — restore it; it holds the settings table.' -ForegroundColor Red
    exit 1
}

# The table's keys: the hashtable assigned to $OrchestratorConfig.
$assignment = (Read-Ast $Config).Find({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and (Test-TableVariable $n.Left)
}, $true)
$table = if ($assignment) { $assignment.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) }
if (-not $table) {
    Write-Host '❌ .github/orchestrator/lib/Config.ps1 assigns no hashtable to $OrchestratorConfig — restore the settings table.' -ForegroundColor Red
    exit 1
}
$keys = @($table.KeyValuePairs | ForEach-Object { "$($_.Item1.Value)" } | Where-Object { $_ })

# Every key read anywhere in the orchestrator and the Commands.
$read = [System.Collections.Generic.HashSet[string]]::new()
$sources = @(foreach ($dir in @('.github/orchestrator', '.github/tasks')) {
    $full = Join-Path $RepoRoot $dir
    if (Test-Path -LiteralPath $full) { Get-ChildItem -LiteralPath $full -Recurse -File -Include '*.ps1', '*.psm1' }
})
foreach ($f in $sources) {
    $found = (Read-Ast $f.FullName).FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and (Test-TableVariable $n.Expression)) -or
        ($n -is [System.Management.Automation.Language.IndexExpressionAst] -and (Test-TableVariable $n.Target))
    }, $true)
    foreach ($n in $found) {
        $key = if ($n -is [System.Management.Automation.Language.MemberExpressionAst]) { $n.Member } else { $n.Index }
        if ($key -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$read.Add($key.Value) }
    }
}

$unread = @($keys | Where-Object { -not $read.Contains($_) })
foreach ($k in $unread) {
    Write-Host "❌ The setting '$k' in .github/orchestrator/lib/Config.ps1 is read by nothing — read it where it applies, or remove it from `$OrchestratorConfig." -ForegroundColor Red
}
if ($unread.Count -gt 0) {
    Write-Host "❌ $($unread.Count) of $($keys.Count) setting(s) read by nothing." -ForegroundColor Red
    exit 1
}
Write-Host "✅ Every one of the $($keys.Count) settings in `$OrchestratorConfig is read." -ForegroundColor Green
exit 0
