#Requires -Version 7.0
<#
.SYNOPSIS
    Phase A.5 — Architecting: blast-radius computation between refine and implement.

.DESCRIPTION
    Internal function library — dot-sourced by implement.ps1. Not a direct Taskfile target.

    Runs between Invoke-Refine and Invoke-Develop:
      1. Creates .planning/<issue>/ for per-issue artifacts.
      2. File-count gate: if src/ has > 5 .py files, runs AST analysis (and attempts pydeps
         for a raw graph). For trivial codebases (<=5 files) writes a one-liner BLAST_RADIUS.md
         so small forks do not get fake graphs — per architecture/SKILL.md §Common Mistakes.
      3. Regenerates docs/CODEBASE_MAP.md from static analysis (written to filesystem,
         never loaded into the agent context window).
      4. Posts a blast-radius comment to the issue (and to any open PR if one exists).
      5. Records the 'architecting' phase transition in .planning/<issue>/state.json.
#>

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

# ── State.json helpers ────────────────────────────────────────────────────────

function Get-PipelineState {
    param([int]$IssueNumber)
    $statePath = "$_Root\.planning\$IssueNumber\state.json"
    if (-not (Test-Path $statePath)) {
        return [pscustomobject]@{ issue = $IssueNumber; transitions = @() }
    }
    try {
        $parsed = Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return $parsed
    } catch {
        return [pscustomobject]@{ issue = $IssueNumber; transitions = @() }
    }
}

function Set-PipelineState {
    param([int]$IssueNumber, [string]$Phase)

    $planDir   = "$_Root\.planning\$IssueNumber"
    $statePath = "$planDir\state.json"
    $null      = New-Item -ItemType Directory -Force -Path $planDir

    # Load existing transitions (always kept as an array)
    $transitions = @()
    if (Test-Path $statePath) {
        try {
            $existing = Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $existing.transitions) {
                $transitions = @($existing.transitions)
            }
        } catch {}
    }

    $transitions += [pscustomobject]@{
        phase     = $Phase
        timestamp = (Get-Date -Format 'o')
    }

    # Build JSON manually to guarantee the transitions key is always a JSON array,
    # even when it contains a single entry (ConvertTo-Json collapses single-item
    # arrays to objects in some PS versions).
    $entriesJson = ($transitions | ForEach-Object {
        $ts = $_.timestamp -replace '"', '\"'
        $ph = $_.phase     -replace '"', '\"'
        "  {`"phase`":`"$ph`",`"timestamp`":`"$ts`"}"
    }) -join ",`n"

    $json = "{`n  `"issue`": $IssueNumber,`n  `"transitions`": [`n$entriesJson`n  ]`n}"
    $json | Set-Content $statePath -Encoding utf8 -NoNewline
    Write-Log "  State: '$Phase' recorded → $statePath" -Color DarkGray
}

# ── AST-based codebase analysis ───────────────────────────────────────────────

# Runs a Python inline script to collect fan-in / fan-out metrics for every
# .py file in src/. Output goes to the filesystem; never loaded in full.
function Invoke-CodebaseAnalysis {
    param([string]$SrcPath)

    $pyScript = @'
import ast, json, pathlib, collections, sys

src = pathlib.Path("src")
if not src.exists():
    print(json.dumps({"modules": [], "fan_out": {}, "fan_in": {}}))
    sys.exit(0)

fan_out = {}
for f in sorted(src.rglob("*.py")):
    rel = str(f.relative_to(src).with_suffix("")).replace("\\", ".").replace("/", ".")
    try:
        tree = ast.parse(f.read_text(encoding="utf-8", errors="replace"))
        deps = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    deps.add(alias.name)
            elif isinstance(node, ast.ImportFrom) and node.module:
                if node.level > 0 or node.module.startswith("src"):
                    deps.add(node.module)
        fan_out[rel] = sorted(deps - {""})
    except Exception:
        fan_out[rel] = []

fan_in: dict = collections.defaultdict(list)
for mod, deps in fan_out.items():
    for dep in deps:
        fan_in[dep].append(mod)

print(json.dumps({
    "modules": sorted(fan_out.keys()),
    "fan_out": fan_out,
    "fan_in": dict(fan_in)
}))
'@

    $pyTmp = New-TemporaryFile
    try {
        $pyScript | Out-File $pyTmp.FullName -Encoding utf8
        $jsonOut = uv run python $pyTmp.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or -not $jsonOut.Trim()) { return $null }
        return $jsonOut.Trim() | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    } finally {
        Remove-Item $pyTmp.FullName -ErrorAction SilentlyContinue
    }
}

# ── CODEBASE_MAP.md generator ─────────────────────────────────────────────────

# Writes docs/CODEBASE_MAP.md from static analysis. Output is filesystem-only;
# the function returns the parsed data object for downstream use.
function Write-CodebaseMap {
    param([string]$OutputPath, [int]$PyFileCount)

    $mapDir = Split-Path $OutputPath
    $null   = New-Item -ItemType Directory -Force -Path $mapDir

    $data = Invoke-CodebaseAnalysis -SrcPath 'src'

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Codebase Map')
    $lines.Add('')
    $lines.Add('*Generated by the architecture phase — do not edit manually.*')
    $lines.Add('*Re-run: `.github/scripts/kanban/architecture.ps1`*')
    $lines.Add('')
    $lines.Add('## Module Summary')
    $lines.Add('')
    $lines.Add('| Module | Fan-in | Fan-out | Classification |')
    $lines.Add('|--------|--------|---------|----------------|')

    if ($data -and $data.modules -and $data.modules.Count -gt 0) {
        foreach ($mod in $data.modules) {
            $fi  = if ($data.fan_in.$mod)  { @($data.fan_in.$mod).Count  } else { 0 }
            $fo  = if ($data.fan_out.$mod) { @($data.fan_out.$mod | Where-Object { $_ }).Count } else { 0 }
            $cls = if     ($fi -gt 3)               { 'high fan-in (god module risk)' }
                   elseif ($fo -eq 0 -and $fi -eq 0) { 'isolated' }
                   elseif ($fo -gt $fi)              { 'deep module (target state)' }
                   else                              { 'shallow module (refactor trigger)' }
            $lines.Add("| ``$mod`` | $fi | $fo | $cls |")
        }
    } else {
        $lines.Add('| *(analysis unavailable)* | — | — | — |')
    }

    $lines.Add('')
    $lines.Add('## Legend')
    $lines.Add('')
    $lines.Add('| Term | Meaning |')
    $lines.Add('|------|---------|')
    $lines.Add('| Fan-in  | Number of modules that import this module — high fan-in = wide blast radius |')
    $lines.Add('| Fan-out | Number of modules this module imports |')
    $lines.Add('| Deep module    | Large implementation, small interface — target state |')
    $lines.Add('| Shallow module | Interface ≈ implementation complexity — refactoring trigger |')
    $lines.Add('| High fan-in    | Risk: a change here propagates to many callers |')
    $lines.Add('')
    $lines.Add("*Last generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC) | $PyFileCount .py file(s) in src/*")

    ($lines -join "`n") | Set-Content $OutputPath -Encoding utf8
    Write-Log "  docs/CODEBASE_MAP.md regenerated ($PyFileCount .py file(s))" -Color DarkGray
    return $data
}

# ── Architecture phase entry point ────────────────────────────────────────────

function Invoke-Architecture {
    param([int]$IssueNumber)
    Write-Log "  Phase A.5 — Architecture for issue #$IssueNumber" -Color Yellow

    $planDir         = "$_Root\.planning\$IssueNumber"
    $blastRadiusPath = "$planDir\BLAST_RADIUS.md"
    $codemapPath     = "$_Root\docs\CODEBASE_MAP.md"
    $null            = New-Item -ItemType Directory -Force -Path $planDir

    # Record the 'architecting' state transition
    Set-PipelineState -IssueNumber $IssueNumber -Phase 'architecting'

    # ── File-count gate ───────────────────────────────────────────────────────
    $pyCount = @(Get-ChildItem "$_Root\src" -Recurse -Filter '*.py' -ErrorAction SilentlyContinue).Count

    if ($pyCount -le 5) {
        # Trivial codebase — one-liner only; no fake graphs
        'trivial codebase, no architectural risk computed' | Set-Content $blastRadiusPath -Encoding utf8

        $trivialMap = @(
            '# Codebase Map'
            ''
            "*Trivial codebase ($pyCount .py file(s) in src/) — no structural analysis performed.*"
            '*Generated by the architecture phase — do not edit manually.*'
        ) -join "`n"
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $codemapPath)
        $trivialMap | Set-Content $codemapPath -Encoding utf8

        $blastComment = @(
            '## Blast-Radius Report'
            ''
            "**Changed:** (architecture phase — pre-implementation, trivial codebase)"
            "**At-risk:** none ($pyCount .py file(s) in src/ — below threshold)"
            '**Safe:** all modules'
            ''
            '**Recommendation:** proceed'
        ) -join "`n"

        Write-Log "  Trivial codebase ($pyCount .py files) — one-liner written." -Color DarkGray

    } else {
        # Non-trivial codebase — run static analysis
        Write-Log "  Non-trivial codebase ($pyCount .py files) — running static analysis..." -Color DarkGray

        # Try pydeps for supplemental raw graph (output to filesystem only)
        $pydepsPath = "$planDir\deps_raw.json"
        try {
            $rawOut = uv run --with pydeps pydeps src --show-deps 2>$null | Out-String
            if ($LASTEXITCODE -eq 0 -and $rawOut.Trim()) {
                $rawOut.Trim() | Set-Content $pydepsPath -Encoding utf8
                Write-Log "  pydeps raw graph → $pydepsPath" -Color DarkGray
            } elseif (Test-Path 'src.json') {
                # pydeps may write src.json to CWD
                Move-Item 'src.json' $pydepsPath -Force -ErrorAction SilentlyContinue
                Write-Log "  pydeps src.json → $pydepsPath" -Color DarkGray
            }
        } catch {
            Write-Log "  pydeps not available — AST fallback only" -Color Yellow
        }

        # Generate CODEBASE_MAP.md and get module data
        $mapData = Write-CodebaseMap -OutputPath $codemapPath -PyFileCount $pyCount

        # Compute blast-radius summary
        $atRisk = [System.Collections.Generic.List[string]]::new()
        $safe   = [System.Collections.Generic.List[string]]::new()

        if ($mapData -and $mapData.modules) {
            foreach ($mod in $mapData.modules) {
                $fi = if ($mapData.fan_in.$mod) { @($mapData.fan_in.$mod).Count } else { 0 }
                if ($fi -gt 3) {
                    $atRisk.Add("$mod (fan-in=$fi)")
                } else {
                    $safe.Add($mod)
                }
            }
        }

        $atRiskStr = if ($atRisk.Count -gt 0) { $atRisk -join ', ' } else { 'none' }
        $safeStr   = if ($safe.Count   -gt 0) { ($safe | Select-Object -First 5) -join ', '
                     if ($safe.Count -gt 5) { $safeStr += " … +$($safe.Count - 5) more" } } else { 'none' }
        $rec       = if ($atRisk.Count -gt 0) { 'refactor first — high fan-in modules detected' } else { 'proceed' }

        $blastComment = @(
            '## Blast-Radius Report'
            ''
            '**Changed:** (architecture phase — pre-implementation analysis)'
            "**At-risk:** $atRiskStr"
            "**Safe:** $safeStr"
            ''
            "**Recommendation:** $rec"
        ) -join "`n"

        $blastComment | Set-Content $blastRadiusPath -Encoding utf8
    }

    Write-Log "  BLAST_RADIUS.md → $blastRadiusPath" -Color DarkGray

    # ── Post blast-radius as issue comment ────────────────────────────────────
    Add-Comment -Number $IssueNumber -Body $blastComment

    # Also post as PR comment if an open PR exists (retry cycles)
    $branch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($branch -and $branch -ne 'HEAD') {
        try {
            $prList = gh pr list --head $branch --json number --limit 1 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($prList -and @($prList).Count -gt 0) {
                $prNum = $prList[0].number
                $tmp   = New-TemporaryFile
                try {
                    $blastComment | Out-File $tmp.FullName -Encoding utf8
                    gh pr comment $prNum --repo $KanbanRepo --body-file $tmp.FullName 2>&1 | Out-Null
                    Write-Log "  Blast-radius posted to PR #$prNum" -Color DarkGray
                } finally {
                    Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
                }
            }
        } catch {
            Write-Log "  Could not post PR comment — $($_)" -Color Yellow
        }
    }

    Add-Comment -Number $IssueNumber -Body '· architecture complete — BLAST_RADIUS.md emitted'
    Write-Log "  Architecture phase complete for issue #$IssueNumber." -Color Green
}
