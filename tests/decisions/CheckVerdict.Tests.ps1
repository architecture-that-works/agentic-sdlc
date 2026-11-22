#Requires -Version 7.0
<#
    Decision table — ship's verdict on the checks of the commit it pushed: green (merge),
    failed (a failed attempt naming the checks), or not passed at the ceiling (missing or
    still running: nothing is merged). One row per shape of check runs; each row runs one
    implement → review → ship round through the conductor on a page under docs/ — a
    change ship merges on its own once the checks are green — with one attempt per round
    and the ceiling at 0 (the runs are read once), and asserts what the owner sees.

    The required check names are RequiredChecks in lib/Config.ps1; the rows name a check
    only to fail or drop it.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Docs = @{ 'docs/decisions.md' = "# Decisions`n`nA table holds one decision.`n" }
}

Describe 'Decision: the checks on the pushed commit' {
    BeforeEach {
        $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" -Files (Get-JourneyFiles) -ChecksTimeoutSeconds 0
        $script:retries = Get-OrchestratorSetting -Name MaxRetries
        Set-OrchestratorSetting -Name MaxRetries -Value 1
    }
    AfterEach {
        Set-OrchestratorSetting -Name MaxRetries -Value $script:retries
        Stop-Journey $script:repo
    }

    It '<Case>: <Verdict>' -ForEach @(
        @{ Case = 'every required check passed';                       Verdict = 'merged' }
        @{ Case = 'eval skipped, every other passed';                  Verdict = 'merged'; Conclusions = @{ eval = 'skipped' } }
        @{ Case = 'an older failed run, the newest passed';            Verdict = 'merged'; Runs = @(@{ Name = 'test'; Conclusion = 'failure'; Age = 'older' }) }
        @{ Case = 'a run reported in progress with a success';         Verdict = 'merged'; Missing = @('lint'); Runs = @(@{ Name = 'lint'; Conclusion = 'success'; Status = 'in_progress' }) }
        @{ Case = 'a failed run on another commit';                    Verdict = 'merged'; Runs = @(@{ Name = 'audit'; Conclusion = 'failure'; OtherCommit = $true }) }
        @{ Case = 'a required check failed';                           Verdict = 'failed: test'; Conclusions = @{ test = 'failure' } }
        @{ Case = 'a required check was cancelled';                    Verdict = 'failed: lint'; Conclusions = @{ lint = 'cancelled' } }
        @{ Case = 'a required check timed out';                        Verdict = 'failed: audit'; Conclusions = @{ audit = 'timed_out' } }
        @{ Case = 'a check that is not required failed';               Verdict = 'failed: docs'; Runs = @(@{ Name = 'docs'; Conclusion = 'failure' }) }
        @{ Case = 'an older passed run, the newest failed';            Verdict = 'failed: typecheck'; Runs = @(@{ Name = 'typecheck'; Conclusion = 'failure' }); Conclusions = @{ typecheck = 'success' } }
        @{ Case = 'a required check has no run';                       Verdict = 'not passed: eval (not reported)'; Missing = @('eval') }
        @{ Case = 'a required check passed only on another commit';    Verdict = 'not passed: checks (not reported)'; Missing = @('checks'); Runs = @(@{ Name = 'checks'; Conclusion = 'success'; OtherCommit = $true }) }
        @{ Case = 'a required check is still running';                 Verdict = 'not passed: audit (not passed)'; Conclusions = @{ audit = $null } }
        @{ Case = 'a required check is neutral';                       Verdict = 'not passed: typecheck (not passed)'; Conclusions = @{ typecheck = 'neutral' } }
    ) {
        $checks = @{}
        if ($Conclusions) { $checks.Conclusions = $Conclusions }
        if ($Missing)     { $checks.Missing = $Missing }
        if ($Runs)        { $checks.Runs = $Runs }
        Set-FakeChecks @checks

        $null = Invoke-BuildRound -Number 52 -Edits $script:Docs

        $story = Get-JourneyStory 52
        $headings = @(Get-FakeCommentHeadings 52)
        switch -Wildcard ($Verdict) {
            'merged' {
                Get-FakePipelineLabel 52 | Should -Be 'agent:shipped' -Because $story
                $headings[-1] | Should -Be '🤖✅ Merged'
            }
            'failed: *' {
                $name = $Verdict.Substring('failed: '.Length)
                Get-FakePipelineLabel 52 | Should -Be 'agent:failed' -Because $story
                $failed = @(Get-FakeComments 52 | Where-Object { $_.Body.StartsWith('🤖❌ CI Failed') })
                $failed.Count | Should -Be 1 -Because $story
                $failed[0].Body | Should -Match "Failed checks: $name — on commit [0-9a-f]{40}\."
            }
            'not passed: *' {
                $line = $Verdict.Substring('not passed: '.Length)
                Get-FakePipelineLabel 52 | Should -Be 'agent:failed' -Because $story
                $waited = @(Get-FakeComments 52 | Where-Object { $_.Body.StartsWith('🤖⚠️ CI did not pass within 0s') })
                $waited.Count | Should -Be 1 -Because $story
                $waited[0].Body | Should -Match ([regex]::Escape("- ``$line``"))
                $headings | Should -Not -Contain '🤖❌ CI Failed'
            }
        }
        if ($Verdict -ne 'merged') {
            Get-RemoteFileContent $script:repo -Branch main -Path 'docs/decisions.md' | Should -BeNullOrEmpty
        }
        Assert-JourneyClean
    }
}
