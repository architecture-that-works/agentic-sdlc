#Requires -Version 7.0
<#
    Repo.ps1 — a temporary git repository with a remote, for one journey.

    New-FakeRepo creates a working tree and a bare repository as its `origin`, commits
    the files the journey starts from on the default branch and pushes it. git runs
    for real, so a test reads what was pushed by asking the remote
    (Get-RemoteBranches, Get-RemoteCommits, Get-RemoteFiles). It then makes the
    working tree the orchestrator's: the current location, and the folder of its log
    and lock files, so nothing a journey does reaches this repository's own clone —
    the conductor resets the working tree to origin when it finishes.

    The working tree holds a stand-in for the full test command
    (.github/tasks/test.ps1): the implement stage runs that command in the tree it
    verifies, and a journey decides what it reports (-TestExit, one exit code per run,
    the last one repeating: @(1, 0) fails the first verification and passes the next)
    instead of running this repository's whole suite inside its own test.

    Someone else's work reaches the remote with Push-RemoteCommit (a commit on the
    default branch, or on a feature branch), from a clone of its own; Sync-FakeRepo
    fetches every branch into the working tree, as a workflow's full checkout does.

    uv commands the stages run in the working tree (the grill's schema check, ruff)
    use this project's environment (UV_PROJECT).

    Remove-FakeRepo puts everything back and deletes the folder.

    Dot-sourced by the journeys; no top-level param() (ADR-013).
#>

function New-FakeRepo {
    param(
        [hashtable]$Files = @{ 'README.md' = "# Sandbox`n" },
        [int[]]$TestExit = @(0),
        [string]$Branch = 'main'
    )
    $module = Get-Module Orchestrator
    if (-not $module) { throw 'New-FakeRepo: import the Orchestrator module first.' }
    $projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath

    $root   = Join-Path ([System.IO.Path]::GetTempPath()) "journey-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $work   = Join-Path $root 'work'
    $remote = Join-Path $root 'remote.git'
    $null = New-Item -ItemType Directory -Force -Path $work, $remote

    # The exit codes, one per run, wait outside the working tree, so the stand-in that
    # reads them is committed once and never changes; the last code repeats.
    $exits = Join-Path $root 'test-exits.txt'
    Set-Content -LiteralPath $exits -Value @($TestExit | ForEach-Object { "$_" }) -Encoding utf8NoBOM
    $stub = @"
#Requires -Version 7.0
# Stand-in for the full test command in a journey's repository (tests/fakes/Repo.ps1).
`$exits = '$($exits.Replace("'", "''"))'
`$codes = @(Get-Content -LiteralPath `$exits | Where-Object { `$_.Trim() })
`$code  = [int]`$codes[0]
if (`$codes.Count -gt 1) { Set-Content -LiteralPath `$exits -Value `$codes[1..(`$codes.Count - 1)] }
Write-Output "pytest  `$(if (`$code -eq 0) { 'passed' } else { 'failed' })  0.1s"
if (`$code -ne 0) { Write-Output 'FAILED tests/test_main.py::test_greeting - AssertionError: the greeting names nobody' }
Write-Output 'Pester  passed  0.1s  line coverage 0.0% of .github/orchestrator/'
exit `$code
"@
    $all = @{} + $Files
    $all['.github/tasks/test.ps1'] = $stub
    foreach ($path in $all.Keys) {
        $full = Join-Path $work $path
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
        Set-Content -LiteralPath $full -Value $all[$path] -Encoding utf8NoBOM -NoNewline
    }

    $git = {
        param([string]$Dir, [string[]]$GitArgs)
        $out = & git -C $Dir @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in ${Dir}: $($out | Out-String)" }
    }
    & $git $remote @('init', '--quiet', '--bare', '-b', $Branch)
    & $git $work @('init', '--quiet', '-b', $Branch)
    # Both repositories get an identity: the fake GitHub's squash merge runs
    # `git commit-tree` in the bare remote, and a runner may have no global identity.
    foreach ($dir in @($work, $remote)) {
        & $git $dir @('config', 'user.name', 'Journey')
        & $git $dir @('config', 'user.email', 'journey@example.invalid')
        & $git $dir @('config', 'commit.gpgsign', 'false')
    }
    & $git $work @('add', '-A')
    & $git $work @('commit', '--quiet', '-m', 'chore: start')
    & $git $work @('remote', 'add', 'origin', $remote)
    & $git $work @('push', '--quiet', '-u', 'origin', $Branch)
    & $git $work @('remote', 'set-head', 'origin', $Branch)

    $saved = & $module { @{ Log = $KanbanLogFile; Lock = $OrchestratorLockFile } }
    $logs  = Join-Path $root 'logs'
    & $module { param($Log, $Lock) $script:KanbanLogFile = $Log; $script:OrchestratorLockFile = $Lock } `
        (Join-Path $logs 'kanban.log') (Join-Path $logs 'orchestrator.lock')

    $repo = [pscustomobject]@{
        Root        = $root
        Work        = $work
        Remote      = $remote
        Branch      = $Branch
        Saved       = $saved
        UvProject   = $env:UV_PROJECT
    }
    $env:UV_PROJECT = $projectRoot
    Push-Location -LiteralPath $work
    return $repo
}

function Remove-FakeRepo {
    param([Parameter(Mandatory)]$Repo)
    Pop-Location
    $env:UV_PROJECT = $Repo.UvProject
    $module = Get-Module Orchestrator
    if ($module) {
        & $module { param($Log, $Lock) $script:KanbanLogFile = $Log; $script:OrchestratorLockFile = $Lock } $Repo.Saved.Log $Repo.Saved.Lock
    }
    Remove-Item -LiteralPath $Repo.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# Pushes one commit to -Branch on the remote — someone else's work, made in a clone of
# its own so the orchestrator's working tree is not touched. -Files @{ path = content }
# ($null content deletes the file). A branch the remote does not have starts from the
# default branch. Returns the new commit's sha.
function Push-RemoteCommit {
    param(
        [Parameter(Mandatory)]$Repo,
        [Parameter(Mandatory)][hashtable]$Files,
        [string]$Branch = $Repo.Branch,
        [string]$Message = 'chore: someone else moves on'
    )
    $clone = Join-Path $Repo.Root "other-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $git = {
        param([string[]]$GitArgs)
        $out = & git -C $clone @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in ${clone}: $($out | Out-String)" }
        return @($out | ForEach-Object { "$_" })
    }
    try {
        $out = & git clone --quiet $Repo.Remote $clone 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git clone of the fake remote failed: $($out | Out-String)" }
        & $git @('config', 'user.name', 'Someone Else') | Out-Null
        & $git @('config', 'user.email', 'someone@example.invalid') | Out-Null
        & $git @('config', 'commit.gpgsign', 'false') | Out-Null
        $exists = @(& $git @('ls-remote', '--heads', 'origin', $Branch)).Count -gt 0
        $start  = if ($exists) { "origin/$Branch" } else { "origin/$($Repo.Branch)" }
        & $git @('checkout', '--quiet', '-B', $Branch, $start) | Out-Null
        foreach ($path in $Files.Keys) {
            $full = Join-Path $clone $path
            if ($null -eq $Files[$path]) { Remove-Item -LiteralPath $full -Force; continue }
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $full)
            Set-Content -LiteralPath $full -Value $Files[$path] -Encoding utf8NoBOM -NoNewline
        }
        & $git @('add', '-A') | Out-Null
        & $git @('commit', '--quiet', '-m', $Message) | Out-Null
        & $git @('push', '--quiet', 'origin', "HEAD:refs/heads/$Branch") | Out-Null
        return @(& $git @('rev-parse', 'HEAD'))[0]
    } finally {
        Remove-Item -LiteralPath $clone -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Fetches every branch of the remote into the working tree (pruning deleted ones), as
# a workflow job's full checkout (fetch-depth 0) has them before it calls the module.
function Sync-FakeRepo {
    param([Parameter(Mandatory)]$Repo)
    $out = & git -C $Repo.Work fetch --quiet --prune origin '+refs/heads/*:refs/remotes/origin/*' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git fetch in the working tree failed: $($out | Out-String)" }
}

# The tip commit of -Branch on the remote ($null when the remote has no such branch).
function Get-RemoteHead {
    param([Parameter(Mandatory)]$Repo, [Parameter(Mandatory)][string]$Branch)
    $sha = @(git --git-dir $Repo.Remote for-each-ref --format='%(objectname)' "refs/heads/$Branch" 2>$null)
    return $sha | Select-Object -First 1
}

# The content of one file on -Branch of the remote ($null when it has no such file).
function Get-RemoteFileContent {
    param([Parameter(Mandatory)]$Repo, [Parameter(Mandatory)][string]$Branch, [Parameter(Mandatory)][string]$Path)
    $out = @(git --git-dir $Repo.Remote show "refs/heads/${Branch}:$Path" 2>$null)
    $found = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if (-not $found) { return $null }
    return ($out -join "`n")
}

# Branch names on the remote.
function Get-RemoteBranches {
    param([Parameter(Mandatory)]$Repo)
    return @(git --git-dir $Repo.Remote for-each-ref --format='%(refname:short)' refs/heads/ 2>$null)
}

# Subjects of the commits on -Branch that the default branch does not have, newest first.
function Get-RemoteCommits {
    param([Parameter(Mandatory)]$Repo, [Parameter(Mandatory)][string]$Branch)
    return @(git --git-dir $Repo.Remote log --format=%s "refs/heads/$($Repo.Branch)..refs/heads/$Branch" 2>$null)
}

# Files -Branch changes against the default branch on the remote.
function Get-RemoteFiles {
    param([Parameter(Mandatory)]$Repo, [Parameter(Mandatory)][string]$Branch)
    return @(git --git-dir $Repo.Remote diff --name-only "refs/heads/$($Repo.Branch)...refs/heads/$Branch" 2>$null)
}
