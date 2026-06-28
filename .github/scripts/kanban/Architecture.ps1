#Requires -Version 7.0
<#
.SYNOPSIS
    Backlog gate, Architect step -- blast-radius impact written into the issue.

.DESCRIPTION
    Kanban library -- loaded by Kanban.psm1; Invoke-Architecture is called by
    Invoke-Alignment (Refine.ps1) between Refine and Plan, as part of the
    pre-backlog alignment that grants agent:backlog.

    Computes the architectural blast radius for the change and records it as the
    `## Architecture Impact` section IN the issue body (ADR-014 -- the issue is the
    single cross-runtime carrier; there is no .planning/ directory). Then marks
    readiness.architected in the issue-carried state so Test-Readiness can clear.

      1. File-count gate: if src/ has > 5 .py files, run AST analysis for fan-in /
         fan-out metrics. For trivial codebases (<= 5 files) emit a one-liner so
         small forks do not get fake graphs -- per architecture/SKILL.md.
      2. Upsert the `## Architecture Impact` body section (Set-IssueBodySection).
      3. Set readiness.architected (Set-PlanningReadiness).
#>

$ErrorActionPreference = 'Stop'
# Module-internal library -- loaded by Kanban.psm1 (which loads Config.ps1 first).
# Not dot-sourced individually; see ADR-013.

# ── AST-based codebase analysis ───────────────────────────────────────────────

# Runs a Python inline script to collect fan-in / fan-out metrics for every
# .py file in src/. Returns the parsed data object for the blast-radius report.
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
        if ($LASTEXITCODE -ne 0 -or -not $jsonOut.Trim()) {
            Write-Log "  ⚠️ Codebase analysis produced no output — blast-radius will list no at-risk modules." -Color Yellow
            return $null
        }
        return $jsonOut.Trim() | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "  ⚠️ Codebase analysis failed to parse — blast-radius will list no at-risk modules. $_" -Color Yellow
        return $null
    } finally {
        Remove-Item $pyTmp.FullName -ErrorAction SilentlyContinue
    }
}

# ── Architect step entry point ────────────────────────────────────────────────

function Invoke-Architecture {
    param([int]$IssueNumber)
    Write-Log "  Architect — blast-radius for issue #$IssueNumber" -Color Yellow

    # ── File-count gate ───────────────────────────────────────────────────────
    $pyCount = @(Get-ChildItem "$_Root\src" -Recurse -Filter '*.py' -ErrorAction SilentlyContinue).Count

    if ($pyCount -le 5) {
        # Trivial codebase — no fake graphs.
        $impact = @(
            "**At-risk:** none ($pyCount .py file(s) in src/ — below the analysis threshold)"
            '**Safe:** all modules'
            ''
            '**Recommendation:** proceed'
        ) -join "`n"
        Write-Log "  Trivial codebase ($pyCount .py files) — one-liner impact." -Color DarkGray

    } else {
        # Non-trivial codebase — run static analysis.
        Write-Log "  Non-trivial codebase ($pyCount .py files) — running static analysis..." -Color DarkGray

        $mapData = Invoke-CodebaseAnalysis -SrcPath 'src'

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
        if ($safe.Count -gt 0) {
            $safeStr = ($safe | Select-Object -First 5) -join ', '
            if ($safe.Count -gt 5) { $safeStr += " … +$($safe.Count - 5) more" }
        } else {
            $safeStr = 'none'
        }
        $rec = if ($atRisk.Count -gt 0) { 'refactor first — high fan-in modules detected' } else { 'proceed' }

        $impact = @(
            "**At-risk:** $atRiskStr"
            "**Safe:** $safeStr"
            ''
            "**Recommendation:** $rec"
        ) -join "`n"
    }

    # ── Write the impact INTO the issue body (no .planning/) ───────────────────
    $section = "## Architecture Impact`n`n$impact"
    $ok = Set-IssueBodySection -IssueNumber $IssueNumber `
        -BeginMarker $KanbanArchBeginMarker -EndMarker $KanbanArchEndMarker -Markdown $section
    if ($ok) {
        Write-Log "  Architecture Impact written to issue #$IssueNumber body." -Color DarkGray
    }

    # ── Mark readiness.architected in the issue-carried state ──────────────────
    Set-PlanningReadiness -IssueNumber $IssueNumber -Stage 'architected' -StageLabel 'architect' `
        -PopulatedBy "architecture (blast-radius, $pyCount files)"

    Add-Comment -Number $IssueNumber -Body '· architected — blast-radius impact written to issue body'
    Write-Log "  Issue #$IssueNumber — readiness.architected ✓" -Color Green
}
