#Requires -Version 7.0
<#
.SYNOPSIS
    Asserts that every backtick-quoted Verb-Noun function name in load-bearing
    documents resolves to a function defined in .github/orchestrator/.

.DESCRIPTION
    check-doc-paths.ps1 guards filesystem paths in agent-load-bearing documents.
    This script guards the other class of drift: an orchestrator function renamed
    or deleted while a navigational document still cites the old name, routing
    every future agent session to a function that does not exist.

    A candidate is recognised only when it appears inside a backtick span AND
    matches the PowerShell Verb-Noun shape (^[A-Z][a-z]+-[A-Z][\w-]*$). That
    double filter rejects media types, parameter flags, paths, prose fragments,
    and inline code that merely contains a hyphen — the same class of false
    positives that check-module-api.ps1 produced before its scope was tightened.

    Scope is deliberately narrow: the template ADR index (the navigational index
    agents load for every orchestrator task), the top-level agent instructions,
    the test README, and skill documents (EXAMPLES.md excluded — illustrative
    content may cite fictional names).

    CONTEXT.md is excluded: it uses PowerShell core cmdlets such as Import-Module
    in descriptive prose; those are PS built-ins, not orchestrator functions, and
    the Module Map exception in AGENTS.md already governs function accuracy there.

    ADR body files are excluded: they are historical decision records that may
    legitimately cite renamed or deleted functions as evidence of past decisions.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath

# Collect every function defined anywhere in the orchestrator module library.
# Public and private both: CONTEXT.md's Module Map cites private stage functions
# (Invoke-Refine, Invoke-Architect, etc.) that are real and must not be flagged.
$orchestratorFiles = @(
    Get-ChildItem -Path (Join-Path $RepoRoot '.github/orchestrator') -Filter '*.psm1' -File
    Get-ChildItem -Path (Join-Path $RepoRoot '.github/orchestrator') -Filter '*.ps1'  -File -Recurse
)
$knownFunctions = @{}
foreach ($file in $orchestratorFiles) {
    $content = Get-Content $file.FullName -Raw
    foreach ($m in [regex]::Matches($content, '(?m)^\s*function\s+([A-Z][a-z]+-[A-Z][\w-]*)')) {
        $knownFunctions[$m.Groups[1].Value] = $true
    }
}

# Documents an agent must be able to trust for orchestrator function names.
$docsToCheck = @(
    Get-Item -Path (Join-Path $RepoRoot 'AGENTS.md')
    Get-Item -Path (Join-Path $RepoRoot 'template/adr/README.md')
    # tests/README.md if present (absent in some generated projects)
    Get-Item -Path (Join-Path $RepoRoot 'tests/README.md') -ErrorAction SilentlyContinue
    # EXAMPLES.md excluded: worked examples describe fictional features.
    Get-ChildItem -Path (Join-Path $RepoRoot '.agents/skills') -Filter '*.md' -File -Recurse |
        Where-Object { $_.Name -ne 'EXAMPLES.md' }
) | Where-Object { $_ -ne $null }

# Verb-Noun shape: capitalised verb, hyphen, capitalised noun/stem, word chars only.
$verbNounShape = '^[A-Z][a-z]+-[A-Z][\w-]*$'

$failures  = @()
$checkedCount = 0

foreach ($doc in $docsToCheck) {
    $relativeDoc = [IO.Path]::GetRelativePath($RepoRoot, $doc.FullName).Replace('\', '/')
    $content = Get-Content -Path $doc.FullName -Raw
    if (-not $content) { continue }

    $seen = @{}
    foreach ($m in [regex]::Matches($content, '`([^`\r\n]+)`')) {
        $token = $m.Groups[1].Value.Trim()
        if ($token -cnotmatch $verbNounShape) { continue }
        if ($seen.ContainsKey($token)) { continue }
        $seen[$token] = $true
        $checkedCount++

        if (-not $knownFunctions.ContainsKey($token)) {
            $failures += [pscustomobject]@{ Doc = $relativeDoc; Name = $token }
        }
    }
}

foreach ($failure in $failures) {
    Write-Host "❌ $($failure.Doc): unknown function — $($failure.Name)" -ForegroundColor Red
}

if ($failures.Count -gt 0) {
    Write-Host ''
    $docCount = ($failures | Select-Object -ExpandProperty Doc -Unique).Count
    Write-Host "❌ $($failures.Count) unknown function name(s) across $docCount load-bearing document(s)." -ForegroundColor Red
    Write-Host "   Update the document to name the current function, or add it to the orchestrator." -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ All $checkedCount Verb-Noun function name(s) in load-bearing documents resolve." -ForegroundColor Green
exit 0
