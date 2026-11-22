#Requires -Version 7.0
<#
.SYNOPSIS
    Guards the Library/Runnable contract of every PowerShell script (ADR-013): a library
    declares no top-level param(), a runnable is never dot-sourced, and every script
    requires PowerShell 7.

.DESCRIPTION
    Dot-sourcing a file runs its top-level param() block in the caller's scope, where its
    defaults silently overwrite the caller's variables — that is how a probe's
    `param([int]$Issue = 0)` once ran the whole pipeline against issue #0. So:

    requires   every .ps1 and .psm1 holds `#Requires -Version 7.0` (or a later 7.x).
    library    a Library — a PascalCase .ps1, or any file another script dot-sources by
               a "$PSScriptRoot..." path — declares no top-level param().
    runnable   a Runnable — a lowercase .ps1 — is invoked, never dot-sourced.
    path       every "$PSScriptRoot..." path a script names resolves to a file or folder
               inside the repository.
    state      a Command in .github/tasks/ that uses a $Kanban* variable sets it itself:
               the module's run state is private to it.

    Scans .github/ and .agents/skills/. Exits 0 when every rule holds; exits 1 with one
    line per violation, naming the file, the rule and what to change.

.EXAMPLE
    pwsh .github/checks/check-script-contract.ps1
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath

function Get-RelativePath([string]$FullName) {
    [IO.Path]::GetRelativePath($RepoRoot, $FullName).Replace('\', '/')
}

$files = @(foreach ($dir in @('.github', '.agents/skills')) {
    $full = Join-Path $RepoRoot $dir
    if (Test-Path -LiteralPath $full) {
        Get-ChildItem -LiteralPath $full -Recurse -File -Include '*.ps1', '*.psm1'
    }
}) | Sort-Object FullName -Unique

$failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure([string]$File, [string]$Rule, [string]$Message) {
    $failures.Add("❌ ${File}: $Rule — $Message")
}

# Parse every file once: its top-level param() and the files it dot-sources.
$parsed  = @{}
$sourced = @{}   # full path of a dot-sourced file → the files that dot-source it
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    $parsed[$f.FullName] = $ast
    $dots = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
    }, $true)
    foreach ($d in $dots) {
        $target = $d.CommandElements[0]
        if ($target -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst]) { continue }
        if ($target.Value -notmatch '^\$PSScriptRoot([\\/].+)$') { continue }
        $path = [IO.Path]::GetFullPath((Join-Path $f.DirectoryName ($Matches[1].Replace('\', '/').TrimStart('/'))))
        if (-not $sourced.ContainsKey($path)) { $sourced[$path] = [System.Collections.Generic.List[string]]::new() }
        $sourced[$path].Add((Get-RelativePath $f.FullName))
    }
}

foreach ($f in $files) {
    $rel  = Get-RelativePath $f.FullName
    $text = Get-Content -LiteralPath $f.FullName -Raw
    $ast  = $parsed[$f.FullName]

    # ── requires ──
    if ($text -notmatch '(?m)^#Requires -Version 7(\.\d+)*\s*$') {
        Add-Failure $rel 'requires' "add '#Requires -Version 7.0' as its first line; every script targets PowerShell 7"
    }

    if ($f.Extension -ne '.ps1') { continue }
    $isLibrary = [char]::IsUpper($f.Name[0])
    $by = if ($sourced.ContainsKey($f.FullName)) { @($sourced[$f.FullName]) } else { @() }

    # ── library ──
    if (($isLibrary -or $by.Count -gt 0) -and $ast.ParamBlock) {
        $why = if ($by.Count -gt 0) { "dot-sourced by $($by -join ', ')" } else { 'a Library (PascalCase)' }
        Add-Failure $rel 'library' "$why, it declares a top-level param() — remove it; a library takes its run parameters from Get-OrchestratorContext and the KANBAN_* environment"
    }

    # ── runnable ──
    if (-not $isLibrary -and $by.Count -gt 0) {
        Add-Failure $rel 'runnable' "a Runnable (lowercase) dot-sourced by $($by -join ', ') — invoke it with & or pwsh -File, or make it a PascalCase library without a param()"
    }

    # ── path ──
    foreach ($m in [regex]::Matches($text, '\$PSScriptRoot([\\/][^"''\s)]*)')) {
        $target = [IO.Path]::GetFullPath((Join-Path $f.DirectoryName ($m.Groups[1].Value.Replace('\', '/').TrimStart('/'))))
        $inside = -not [IO.Path]::GetRelativePath($RepoRoot, $target).StartsWith('..')
        if (-not $inside -or -not (Test-Path -LiteralPath $target)) {
            Add-Failure $rel 'path' "`$PSScriptRoot$($m.Groups[1].Value) points at $(if ($inside) { Get-RelativePath $target } else { 'a place outside the repository' }), which does not exist — fix the relative path"
        }
    }

    # ── state ──
    if ((Get-RelativePath $f.DirectoryName) -eq '.github/tasks') {
        foreach ($var in @([regex]::Matches($text, '\$(Kanban[A-Za-z_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
            if ($text -notmatch "\`$$var\s*=") {
                Add-Failure $rel 'state' "uses `$$var without setting it — the module's run state is private; set it from Get-OrchestratorContext"
            }
        }
    }
}

foreach ($line in $failures) { Write-Host $line -ForegroundColor Red }
if ($failures.Count -gt 0) {
    Write-Host "❌ $($failures.Count) script contract violation(s) in $($files.Count) script(s)." -ForegroundColor Red
    exit 1
}
Write-Host "✅ Script contract holds for $($files.Count) script(s): libraries take no param(), runnables are never dot-sourced, every script requires PowerShell 7." -ForegroundColor Green
exit 0
