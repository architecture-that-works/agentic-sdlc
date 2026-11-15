#Requires -Version 7.0
<#
.SYNOPSIS
    Asserts that every shortcut comment names its follow-up.

.DESCRIPTION
    A shortcut comment that omits its follow-up reference cannot reach main.
    The canonical contract is:
        # shortcut: <reason> — to be fixed in <follow-up-slug>
    (em-dash U+2014 required). Scans src/ and .github/ recursively, excluding
    this script's own path. Exits non-zero and prints offending lines on failure.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath

$scanDirs = @(
    Join-Path $RepoRoot 'src'
    Join-Path $RepoRoot '.github'
)

$shortcutPattern = '#\s*shortcut:'
$emDash = [char]0x2014
$followUpPattern = "$emDash\s*to be fixed in \S+"

$violations = @()

foreach ($dir in $scanDirs) {
    if (-not (Test-Path $dir)) { continue }
    $files = Get-ChildItem -Path $dir -Recurse -File
    foreach ($file in $files) {
        if ($file.FullName -eq $PSCommandPath) { continue }
        $hits = Select-String -Path $file.FullName -Pattern $shortcutPattern -ErrorAction SilentlyContinue
        if (-not $hits) { continue }
        foreach ($hit in $hits) {
            if ($hit.Line -notmatch $followUpPattern) {
                $relPath = [IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
                $violations += "$($relPath):$($hit.LineNumber): $($hit.Line.Trim())"
            }
        }
    }
}

foreach ($v in $violations) {
    Write-Host $v
}

if ($violations.Count -gt 0) {
    exit 1
}

exit 0
