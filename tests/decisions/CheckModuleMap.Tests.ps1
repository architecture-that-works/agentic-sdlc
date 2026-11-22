#Requires -Version 7.0
<#
    Decision table — check-module-map.ps1: a new top-level src/<domain>/ in the change
    needs a Module Map row in CONTEXT.md (ADR-009). Each row commits a base and a change
    in a temporary repository, runs the check against the base, and asserts its exit code
    and the violation it prints.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Check = 'check-module-map.ps1'
    function Get-Context {
        param([string[]]$Domains = @())
        $rows = ($Domains | ForEach-Object { "| $_ | ``src/$_/`` | ``src/$_/`` | TBD |" }) -join "`n"
        return "# CONTEXT.md`n`n## Module Map`n`n| Module | Path | Bounded Context | Entry points |`n|---|---|---|---|`n| config | ``src/config.py`` | ``src/`` | ``Settings`` |`n$rows`n"
    }
}

Describe 'Decision: check-module-map' {
    AfterEach { Remove-CheckRepo $script:root }

    It '<Case> — exit <Exit>' -ForEach @(
        @{ Case = 'a change outside src/';              Base = @{}; Change = @{ 'README.md' = '# readme' }; Exit = 0; Names = @() }
        @{ Case = 'a new domain without a row';         Base = @{}; Change = @{ 'src/newdomain/__init__.py' = '' }; Exit = 1; Names = @('src/newdomain/') }
        @{ Case = 'a new domain with its row';          Base = @{}; Change = @{ 'src/newdomain/__init__.py' = ''; Rows = @('newdomain') }; Exit = 0; Names = @() }
        @{ Case = 'a domain renamed with its row';      Base = @{ 'src/olddomain/__init__.py' = '# old'; Rows = @('olddomain') }
           Change = @{ 'src/olddomain/__init__.py' = $null; 'src/newdomain/__init__.py' = ''; Rows = @('newdomain') }; Exit = 0; Names = @() }
        @{ Case = 'two new domains, one without a row'; Base = @{}; Change = @{ 'src/domain_a/__init__.py' = ''; 'src/domain_b/__init__.py' = ''; Rows = @('domain_a') }
           Exit = 1; Names = @('src/domain_b/') }
        @{ Case = 'a change to a domain the base has';  Base = @{ 'src/known/__init__.py' = '' }; Change = @{ 'src/known/more.py' = '' }; Exit = 0; Names = @() }
    ) {
        $toFiles = { param($h) $f = @{}; foreach ($k in $h.Keys) { if ($k -ne 'Rows') { $f[$k] = $h[$k] } }; $f['CONTEXT.md'] = Get-Context -Domains @($h.Rows | Where-Object { $_ }); $f }
        $script:root = New-CheckRepo -Check $script:Check
        $base = Add-CheckCommit -Root $script:root -Files (& $toFiles $Base) -Message 'base'
        $null = Add-CheckCommit -Root $script:root -Files (& $toFiles $Change) -Message 'change'

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check -Arguments @{ BaseRef = $base }

        $run.Exit | Should -Be $Exit -Because $run.Output
        foreach ($name in $Names) { $run.Output | Should -Match "missing Module Map row for: $([regex]::Escape($name))" }
        if ($Exit -eq 1) { @($run.Lines | Where-Object { $_ -like '*FAIL*' }).Count | Should -Be $Names.Count }
    }

    It 'passes, saying why, when it cannot diff against the base' {
        $script:root = New-CheckRepo -Check $script:Check

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check -Arguments @{ BaseRef = 'origin/no-such-branch' }

        $run.Exit | Should -Be 0
        $run.Output | Should -Match "cannot diff against 'origin/no-such-branch'"
    }
}
