#Requires -Version 7.0
<#
.SYNOPSIS
    Guards every reference a workflow, the Taskfile or an agent document makes: each script,
    path and orchestrator function it names exists.

.DESCRIPTION
    A stale reference fails silently: a workflow step calls a script that moved, or a document
    every agent session loads routes it to a file or function that is gone. Three rules, each
    with a deliberately narrow source list and shape filter. Widening either drags prose into a
    gate that must stay quiet.

    script    Script paths (.ps1, .psd1, .psm1, .py under .github/ or src/) named in
              .github/workflows/*.yml and Taskfile.yml exist on disk.

    path      Repo-relative paths cited in a backtick span or a markdown link target in
              AGENTS.md, CONTEXT.md, the skill documents and the routed docs (docs/TESTING.md,
              docs/SKILLS.md) exist. A candidate counts only when it starts at a known top-level
              directory and holds nothing but path characters. That one rule, not an exclusion
              list (which rots exactly like the thing it guards), rejects prose that merely holds
              a slash (`Planner/Generator/Evaluator`, `text/event-stream`, `CI/CD`) and template
              placeholders (`src/<domain>/`, `src/utils/m_*.py`). README.md is not covered: it
              is the human front door, not agent-load-bearing.

    function  Backtick-quoted Verb-Noun names in AGENTS.md, tests/README.md and the skill
              documents are defined somewhere in .github/orchestrator/. Public and private both:
              documents cite private stage functions (Invoke-Refine) that are real. CONTEXT.md is
              excluded: it cites core cmdlets such as Import-Module in prose, and the Module Map
              exception in AGENTS.md already governs function accuracy there.

    EXAMPLES.md is excluded from the document rules: a worked example describes a fictional
    feature, so its paths and functions are illustrative. ADR bodies are excluded: they are
    historical records that may cite renamed things as evidence.

    Exits 0 when every reference resolves; exits 1 with one line per missing target, naming the
    source, the kind of reference and the target.

.EXAMPLE
    pwsh .github/checks/check-references.ps1
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath

function Get-RelativePath([string]$FullName) {
    [IO.Path]::GetRelativePath($RepoRoot, $FullName).Replace('\', '/')
}

# Skill documents an agent must be able to trust. EXAMPLES.md excluded (see DESCRIPTION).
$skillDocs = @(
    Get-ChildItem -Path (Join-Path $RepoRoot '.agents/skills') -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'EXAMPLES.md' }
)

function Get-Docs([string[]]$RelativePaths) {
    foreach ($rel in $RelativePaths) {
        Get-Item -Path (Join-Path $RepoRoot $rel) -ErrorAction SilentlyContinue
    }
}

$failures = [System.Collections.Generic.List[object]]::new()
$checked  = @{ script = 0; path = 0; function = 0 }

function Add-Failure([string]$Source, [string]$Kind, [string]$Target) {
    $failures.Add([pscustomobject]@{ Source = $Source; Kind = $Kind; Target = $Target })
}

# ── Rule 1: script paths in the workflows and the Taskfile ────────────────────

$scriptSources = @(
    Get-ChildItem -Path (Join-Path $RepoRoot '.github/workflows') -Filter '*.yml' -File -ErrorAction SilentlyContinue
    Get-Docs @('Taskfile.yml')
) | Where-Object { $_ }

$scriptShape = '(?:\.github|src)[/\w\-\.]+\.(?:ps1|psd1|psm1|py)'
$seenScripts = @{}

foreach ($file in $scriptSources) {
    $source  = Get-RelativePath $file.FullName
    $content = Get-Content -Path $file.FullName -Raw
    if (-not $content) { continue }
    foreach ($m in [regex]::Matches($content, $scriptShape)) {
        $path = $m.Value.Replace('\', '/')
        if ($seenScripts.ContainsKey($path)) { continue }
        $seenScripts[$path] = $true
        $checked.script++
        if (-not (Test-Path -Path (Join-Path $RepoRoot $path))) {
            Add-Failure $source 'script' $path
        }
    }
}

# ── Rule 2: repo-relative paths cited in agent documents ──────────────────────

# Session Initialisation loads AGENTS.md and CONTEXT.md; the Context Protocol navigates by
# the Module Map; skills are invoked by path; docs/*.md routed from § Conditional Context.
$pathSources = @(
    Get-Docs @('AGENTS.md', 'CONTEXT.md', 'docs/TESTING.md', 'docs/SKILLS.md')
    $skillDocs
) | Where-Object { $_ }

# Backtick-quoted spans and markdown link targets — the two ways these documents cite a path.
$citationPatterns = @(
    '`([^`\r\n]+)`'
    '\]\(([^)\r\n]+)\)'
)

# A path starts at a known top-level directory and is built only from path characters.
# `.claude` is not a listed root by design: copier excludes it, so it is absent from every
# generated project — and this check runs there too. For the same reason, a document that
# ships must not cite a template-only path such as copier.yml or
# a test folder that stays home (tests/journeys/, tests/evals/, …); name those in prose,
# without backticks, instead.
$pathShape = '^(src|tests|docs|\.github|\.agents|\.devcontainer)/[\w\-./]*$'

# Naming templates spelled with letters rather than angle brackets, which the path shape
# alone cannot reject (e.g. `docs/adr/ADR-NNN-kebab-title.md`).
$placeholderShape = 'NNN'

foreach ($doc in $pathSources) {
    $source  = Get-RelativePath $doc.FullName
    $content = Get-Content -Path $doc.FullName -Raw
    if (-not $content) { continue }

    $seen = @{}
    foreach ($pattern in $citationPatterns) {
        foreach ($m in [regex]::Matches($content, $pattern)) {
            $candidate = $m.Groups[1].Value.Trim()
            if ($candidate -notmatch $pathShape) { continue }
            if ($candidate -match $placeholderShape) { continue }
            if ($seen.ContainsKey($candidate)) { continue }
            $seen[$candidate] = $true
            $checked.path++
            if (-not (Test-Path -Path (Join-Path $RepoRoot $candidate))) {
                Add-Failure $source 'path' $candidate
            }
        }
    }
}

# ── Rule 3: orchestrator function names cited in agent documents ──────────────

$orchestratorDir   = Join-Path $RepoRoot '.github/orchestrator'
$orchestratorFiles = @(
    Get-ChildItem -Path $orchestratorDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue
    Get-ChildItem -Path $orchestratorDir -Filter '*.ps1'  -File -Recurse -ErrorAction SilentlyContinue
)
$knownFunctions = @{}
foreach ($file in $orchestratorFiles) {
    $content = Get-Content $file.FullName -Raw
    foreach ($m in [regex]::Matches($content, '(?m)^\s*function\s+([A-Z][a-z]+-[A-Z][\w-]*)')) {
        $knownFunctions[$m.Groups[1].Value] = $true
    }
}

$functionSources = @(
    Get-Docs @('AGENTS.md', 'tests/README.md')
    $skillDocs
) | Where-Object { $_ }

# Verb-Noun shape: capitalised verb, hyphen, capitalised noun/stem, word chars only. Together
# with the backtick span it rejects media types, parameter flags, paths and prose fragments.
$verbNounShape = '^[A-Z][a-z]+-[A-Z][\w-]*$'

foreach ($doc in $functionSources) {
    $source  = Get-RelativePath $doc.FullName
    $content = Get-Content -Path $doc.FullName -Raw
    if (-not $content) { continue }

    $seen = @{}
    foreach ($m in [regex]::Matches($content, '`([^`\r\n]+)`')) {
        $token = $m.Groups[1].Value.Trim()
        if ($token -cnotmatch $verbNounShape) { continue }
        if ($seen.ContainsKey($token)) { continue }
        $seen[$token] = $true
        $checked.function++
        if (-not $knownFunctions.ContainsKey($token)) {
            Add-Failure $source 'function' $token
        }
    }
}

# ── Result ────────────────────────────────────────────────────────────────────

$fixFor = @{
    script   = 'fix the path in the workflow or Taskfile, or restore the script'
    path     = 'fix the path in the document (or the Module Map row that should list it), or restore the file'
    function = 'name the current orchestrator function in the document, or define the function in .github/orchestrator/'
}

foreach ($f in $failures) {
    Write-Host "❌ $($f.Source): $($f.Kind) does not exist — $($f.Target) — $($fixFor[$f.Kind])." -ForegroundColor Red
}

$total = $checked.script + $checked.path + $checked.function
if ($failures.Count -gt 0) {
    Write-Host ''
    $sourceCount = ($failures | Select-Object -ExpandProperty Source -Unique).Count
    Write-Host "❌ $($failures.Count) of $total reference(s) point at nothing, across $sourceCount source(s)." -ForegroundColor Red
    exit 1
}

Write-Host "✅ All $total reference(s) resolve: $($checked.script) script(s), $($checked.path) path(s), $($checked.function) function(s)." -ForegroundColor Green
exit 0
