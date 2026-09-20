$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path "$PSScriptRoot/../..").ProviderPath

$filesToCheck = @(
    Get-ChildItem -Path "$RepoRoot/.github/workflows" -Filter "*.yml" -File
    Get-Item -Path (Join-Path $RepoRoot "Taskfile.yml")
)

$regex = '(?:\.github|src)[/\w\-\.]+\.(?:ps1|psd1|psm1|py)'
$failures = 0
$checked = @{}

foreach ($file in $filesToCheck) {
    if (-not (Test-Path $file.FullName)) { continue }
    $content = Get-Content -Path $file.FullName -Raw
    $matches = [regex]::Matches($content, $regex)
    foreach ($m in $matches) {
        $path = $m.Value.Replace('\', '/')
        
        # Avoid checking same path multiple times
        if ($checked.ContainsKey($path)) { continue }
        $checked[$path] = $true

        $fullPath = Join-Path $RepoRoot $path
        if (-not (Test-Path $fullPath)) {
            Write-Host "❌ Script path does not exist: $path (referenced in $($file.Name))" -ForegroundColor Red
            $failures++
        } else {
            Write-Host "✅ Script path exists: $path" -ForegroundColor DarkGray
        }
    }
}

if ($failures -gt 0) {
    Write-Host "❌ $failures script path(s) referenced in workflows/tasks do not exist on disk." -ForegroundColor Red
    exit 1
}

Write-Host "✅ All script paths referenced in workflows/tasks exist." -ForegroundColor Green
exit 0
