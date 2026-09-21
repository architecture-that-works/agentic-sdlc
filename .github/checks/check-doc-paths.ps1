#Requires -Version 7.0
<#
.SYNOPSIS
    Asserts that every repo-relative path referenced in a load-bearing document exists.

.DESCRIPTION
    check-script-paths.ps1 guards paths referenced from workflows and the Taskfile. This
    guards the other half: the documents an agent is required to load before it may open a
    source file (AGENTS.md § Session Initialisation, § Context Protocol). A stale path there
    routes every future session to a file that is not on disk — silent, and the failure mode
    that ADR-015's own PR 6/7 shipped.

    Scope is deliberately narrow: only files the agentic template cannot function without.
    README.md is NOT covered — it is the human front door, not agent-load-bearing, and
    including it would drag prose-heavy churn into a gate meant to stay quiet.

    A candidate is recognised only when it is unambiguously a repo-relative path: it starts
    with a known top-level directory and contains nothing but path characters. That single
    rule — rather than an exclusion list, which rots exactly like the thing it guards —
    excludes prose that merely contains a slash (`Planner/Generator/Evaluator`,
    `text/event-stream`, `CI/CD`) and template placeholders (`src/<domain>/`,
    `src/utils/m_*.py`), because neither matches the character class.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath

# Documents an agent must be able to trust. Session Initialisation loads 1-3; the Context
# Protocol navigates by the Module Map in CONTEXT.md; skills are invoked by path.
$docsToCheck = @(
    Get-Item -Path (Join-Path $RepoRoot 'AGENTS.md')
    Get-Item -Path (Join-Path $RepoRoot 'CONTEXT.md')
    Get-Item -Path (Join-Path $RepoRoot 'docs/adr/ADR_STRUCTURE.md')
    # EXAMPLES.md is excluded: a worked example describes a fictional feature, so its paths
    # (`src/payments/`, `docs/arch/blast-radius.md`) are illustrative and must not resolve.
    Get-ChildItem -Path (Join-Path $RepoRoot '.agents/skills') -Filter '*.md' -File -Recurse |
        Where-Object { $_.Name -ne 'EXAMPLES.md' }
    # docs/*.md routed from AGENTS.md § Conditional Context
    Get-ChildItem -Path (Join-Path $RepoRoot 'docs') -Filter '*.md' -File |
        Where-Object { $_.Name -in @('TESTING.md', 'SKILLS.md', 'HARNESS.md') }
)

# Backtick-quoted spans and markdown link targets — the two ways these documents cite a path.
$citationPatterns = @(
    '`([^`\r\n]+)`'
    '\]\(([^)\r\n]+)\)'
)

# A path starts at a known top-level directory and is built only from path characters.
# `.claude/` is excluded by design: copier `_exclude`s it, so it is absent from every
# generated project and asserting it would reintroduce the #192 failure mode.
$pathShape = '^(src|tests|docs|\.github|\.agents|\.devcontainer)/[\w\-./]*$'

# Naming templates that are spelled with letters rather than angle brackets, so the path
# shape alone cannot reject them (e.g. `docs/adr/ADR-NNN-kebab-title.md`).
$placeholderShape = 'NNN'

$failures = @()
$checkedCount = 0

foreach ($doc in $docsToCheck) {
    $relativeDoc = [IO.Path]::GetRelativePath($RepoRoot, $doc.FullName).Replace('\', '/')
    $content = Get-Content -Path $doc.FullName -Raw
    if (-not $content) { continue }

    $seen = @{}
    foreach ($pattern in $citationPatterns) {
        foreach ($match in [regex]::Matches($content, $pattern)) {
            $candidate = $match.Groups[1].Value.Trim()

            if ($candidate -notmatch $pathShape) { continue }
            if ($candidate -match $placeholderShape) { continue }
            if ($seen.ContainsKey($candidate)) { continue }
            $seen[$candidate] = $true
            $checkedCount++

            if (-not (Test-Path -Path (Join-Path $RepoRoot $candidate))) {
                $failures += [pscustomobject]@{ Doc = $relativeDoc; Path = $candidate }
            }
        }
    }
}

foreach ($failure in $failures) {
    Write-Host "❌ $($failure.Doc): path does not exist — $($failure.Path)" -ForegroundColor Red
}

if ($failures.Count -gt 0) {
    Write-Host ''
    $docCount = ($failures | Select-Object -ExpandProperty Doc -Unique).Count
    Write-Host "❌ $($failures.Count) stale path(s) across $docCount load-bearing document(s)." -ForegroundColor Red
    Write-Host "   These documents route every agent session. Fix the path, or the Module Map that should list it." -ForegroundColor Yellow
    exit 1
}

Write-Host "✅ All $checkedCount path(s) cited in load-bearing documents exist." -ForegroundColor Green
exit 0
