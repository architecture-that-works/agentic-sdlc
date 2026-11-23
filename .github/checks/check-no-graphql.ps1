#Requires -Version 7.0
<#
.SYNOPSIS
    Guards the GraphQL budget (ADR-012): no script makes a GraphQL call where a REST call
    or the run context serves.

.DESCRIPTION
    `gh repo view`, `gh issue view` and `gh issue edit` go through GitHub's GraphQL API,
    which throttles apart from REST (5000 points an hour each); when it ran out, an empty
    repository slug once broke every later `gh ... --repo ''` call. Three rules:

    repo view   the repository slug and default branch come from the run context
                (Get-OrchestratorContext: GITHUB_REPOSITORY, the git remote), never
                `gh repo view`. The one exception is the documented last-resort fallback
                in .github/orchestrator/lib/Config.ps1, in its guarded form (`2>$null`).
    label write labels change through `gh api .../labels` (REST), never
                `gh issue edit --add-label/--remove-label`.
    label read  labels alone are read through `gh api .../labels` (REST), never
                `gh issue view --json labels`.

    Projects v2 calls (`gh project ...`) have no REST equivalent and are not checked.
    Scans the orchestrator, the Commands, the workflows and the skill scripts; comments
    are skipped, and a call split over lines with backtick continuations is read as one
    line, reported at the line it starts on. Exits 0 when every rule holds; exits 1 with one line per violation.

.EXAMPLE
    pwsh .github/checks/check-no-graphql.ps1
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath
$Fallback = '.github/orchestrator/lib/Config.ps1'

function Get-RelativePath([string]$FullName) {
    [IO.Path]::GetRelativePath($RepoRoot, $FullName).Replace('\', '/')
}

$sources = @(
    @{ Dir = '.github/orchestrator'; Include = @('*.ps1', '*.psm1') }
    @{ Dir = '.github/tasks';        Include = @('*.ps1') }
    @{ Dir = '.github/workflows';    Include = @('*.yml', '*.yaml') }
    @{ Dir = '.agents/skills';       Include = @('*.ps1') }
)
$files = @(foreach ($s in $sources) {
    $full = Join-Path $RepoRoot $s.Dir
    if (Test-Path -LiteralPath $full) { Get-ChildItem -LiteralPath $full -Recurse -File -Include $s.Include }
}) | Sort-Object FullName -Unique

$rules = @(
    @{ Name = 'repo view';   Pattern = 'gh\s+repo\s+view\b'
       Fix  = 'take the slug or default branch from Get-OrchestratorContext (.Repo, .DefaultBranch), or read the repository through gh api repos/<owner>/<repo>' }
    @{ Name = 'label write'; Pattern = '--(add|remove)-label\b'
       Fix  = 'change the label through gh api repos/<owner>/<repo>/issues/<n>/labels' }
    @{ Name = 'label read';  Pattern = 'gh\s+issue\s+view\b.*--json\s+labels(\s|$)'
       Fix  = 'read the labels through gh api repos/<owner>/<repo>/issues/<n>/labels' }
)

$failures = [System.Collections.Generic.List[string]]::new()
foreach ($f in $files) {
    $rel = Get-RelativePath $f.FullName
    $inBlock = $false
    $lines = @(Get-Content -LiteralPath $f.FullName)
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $n = $i + 1
        $i++
        # Comments: <# … #> blocks and full-line # comments.
        if ($inBlock) { if ($line -match '#>') { $inBlock = $false }; continue }
        if ($line -match '^\s*<#') { if ($line -notmatch '#>') { $inBlock = $true }; continue }
        if ($line -match '^\s*#') { continue }
        # A PowerShell call split with a backtick continuation is one call: join it with the
        # lines it continues onto, and report the line it starts on.
        while ($line -match '`\s*$' -and $i -lt $lines.Count) {
            $line = ($line -replace '`\s*$', ' ') + $lines[$i].TrimStart()
            $i++
        }
        foreach ($rule in $rules) {
            if ($line -notmatch $rule.Pattern) { continue }
            if ($rule.Name -eq 'repo view' -and $rel -eq $Fallback -and $line -match '2>\$null') { continue }
            $failures.Add("❌ ${rel}:${n}: $($rule.Name) is a GraphQL call — $($rule.Fix).")
        }
    }
}

foreach ($line in $failures) { Write-Host $line -ForegroundColor Red }
if ($failures.Count -gt 0) {
    Write-Host "❌ $($failures.Count) GraphQL call(s) where REST or the run context serves." -ForegroundColor Red
    exit 1
}
Write-Host "✅ No GraphQL call where REST serves, in $($files.Count) file(s)." -ForegroundColor Green
exit 0
