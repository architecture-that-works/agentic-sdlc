#Requires -Version 7.0
<#
.SYNOPSIS
    Guards the engine boundary: only an engine adapter (.github/orchestrator/engines/)
    starts the engine's CLI or names its flags, and nothing pins the engine by name.

.DESCRIPTION
    Invoke-EngineTask in the adapter is the one function that starts a model; every
    stage passes a task and a prompt, never a model or a CLI flag, and the Engine setting
    in lib/Config.ps1 is the one place that chooses the engine. Two rules:

    cli   outside engines/, no file of the orchestrator or the skills starts `claude`
          (`| claude`, `claude @`) or names one of its flags (--model, --tools,
          --allowedTools, --max-turns, --output-format, --json-schema).
    pin   no file under .github/ passes `-Engine 'claude'`: a caller that names the
          engine overrides the one setting.

    Exits 0 when both hold; exits 1 with one line per violation.

.EXAMPLE
    pwsh .github/checks/check-engine-adapter.ps1
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath
$Engines  = Join-Path $RepoRoot '.github/orchestrator/engines'

function Get-RelativePath([string]$FullName) {
    [IO.Path]::GetRelativePath($RepoRoot, $FullName).Replace('\', '/')
}

function Get-Sources([string]$Dir) {
    $full = Join-Path $RepoRoot $Dir
    if (-not (Test-Path -LiteralPath $full)) { return @() }
    return @(Get-ChildItem -LiteralPath $full -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.yml', '*.md')
}

$cliFlag  = '--(model|allowedTools|tools|max-turns|output-format|json-schema)\b'
$cliStart = '\|\s*claude\b|claude @'
$pin      = "-Engine\s+'claude'"
$checks   = [IO.Path]::GetFullPath($PSScriptRoot)

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($f in @(Get-Sources '.github/orchestrator') + @(Get-Sources '.agents')) {
    if ($f.FullName.StartsWith($Engines)) { continue }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
        $n++
        if ($line -match $cliFlag -or $line -match $cliStart) {
            $failures.Add("❌ $(Get-RelativePath $f.FullName):${n}: cli — only an engine adapter starts the CLI or names its flags; call Invoke-EngineTask with a task instead.")
        }
    }
}
foreach ($f in Get-Sources '.github') {
    if ($f.DirectoryName -eq $checks) { continue }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
        $n++
        if ($line -match $pin) {
            $failures.Add("❌ $(Get-RelativePath $f.FullName):${n}: pin — drop -Engine 'claude'; the Engine setting in .github/orchestrator/lib/Config.ps1 chooses the engine.")
        }
    }
}

foreach ($line in $failures) { Write-Host $line -ForegroundColor Red }
if ($failures.Count -gt 0) {
    Write-Host "❌ $($failures.Count) engine boundary violation(s)." -ForegroundColor Red
    exit 1
}
Write-Host '✅ Only the engine adapter knows the CLI, and nothing pins the engine.' -ForegroundColor Green
exit 0
