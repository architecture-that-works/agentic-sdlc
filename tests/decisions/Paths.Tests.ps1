#Requires -Version 7.0
<#
    Decision table — what happens to a path the agent changes: merged without the owner
    (inside WritablePaths, outside GovernancePaths), held for the owner (a governance
    file, or a proposal outside WritablePaths), or never staged (the secrets denylist).
    One row per path; each row runs one implement → review → ship round through the
    conductor on a change to that path beside a page under docs/, and asserts what the
    owner sees: the label, the hold comment, the denylist comment, and what reached the
    default branch.

    The paths lists are written once, in lib/Config.ps1 ($OrchestratorConfig); the rows
    assert outcomes, never the lists.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Docs = @{ 'docs/decisions.md' = "# Decisions`n`nA table holds one decision.`n" }
}

Describe 'Decision: a changed path' {
    BeforeEach { $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" -Files (Get-JourneyFiles) }
    AfterEach { Stop-Journey $script:repo }

    It '<Path> is <Outcome>' -ForEach @(
        @{ Path = 'src/greeting.py';                         Outcome = 'merged' }
        @{ Path = 'tests/app/test_greeting.py';              Outcome = 'merged' }
        @{ Path = 'docs/guide/journeys.md';                  Outcome = 'merged' }
        @{ Path = 'pyproject.toml';                          Outcome = 'merged' }
        @{ Path = 'docs/secrets-management.md';              Outcome = 'merged' }
        @{ Path = 'CONTEXT.md';                              Outcome = 'held as a governance file' }
        @{ Path = 'docs/adr/ADR-002-secrets-management.md';  Outcome = 'held as a governance file' }
        @{ Path = '.agents/skills/plan/SKILL.md';            Outcome = 'held as a governance file' }
        @{ Path = 'README.md';                               Outcome = 'held as a proposal' }
        @{ Path = 'Dockerfile';                              Outcome = 'held as a proposal' }
        @{ Path = '.github/workflows/ci.yml';                Outcome = 'held as both' }
        @{ Path = '.github/orchestrator/lib/Config.ps1';     Outcome = 'held as both' }
        @{ Path = '.env';                                    Outcome = 'never staged' }
        @{ Path = 'config/deploy.key';                       Outcome = 'never staged' }
        @{ Path = 'certs/site.pem';                          Outcome = 'never staged' }
        @{ Path = 'certs/site.pfx';                          Outcome = 'never staged' }
        @{ Path = 'config/secrets.json';                     Outcome = 'never staged' }
        @{ Path = 'config/db_credentials.json';              Outcome = 'never staged' }
    ) {
        $pr = Invoke-BuildRound -Number 50 -Edits (@{ $Path = "changed`n" } + $script:Docs)

        $story = Get-JourneyStory 50
        $last  = @(Get-FakeComments 50)[-1].Body
        $denied = @(Get-FakeComments 50 | Where-Object { $_.Body.StartsWith('🤖 Secrets Denylist') })
        switch -Wildcard ($Outcome) {
            'merged' {
                Get-FakePipelineLabel 50 | Should -Be 'agent:shipped' -Because $story
                Get-RemoteFileContent $script:repo -Branch main -Path $Path | Should -Be 'changed'
                $denied | Should -BeNullOrEmpty
            }
            'held as *' {
                Get-FakePipelineLabel 50 | Should -Be 'human:approval' -Because $story
                $last | Should -Match ([regex]::Escape("- ``$Path``"))
                $why = @{
                    'held as a governance file' = 'it changes governance files'
                    'held as a proposal'        = 'it changes files outside the agent write allowlist'
                    'held as both'              = 'it changes governance files and files outside the agent write allowlist'
                }[$Outcome]
                $last | Should -Match ([regex]::Escape($why))
                Get-RemoteFileContent $script:repo -Branch main -Path $Path | Should -Not -Be 'changed' -Because 'nothing held reaches the default branch'
            }
            'never staged' {
                $denied.Count | Should -Be 1 -Because $story
                $denied[0].Body | Should -Match ([regex]::Escape("Unstaged by the secrets denylist: $Path"))
                Get-RemoteFiles $script:repo -Branch $pr.Head | Should -Not -Contain $Path
                Get-FakePipelineLabel 50 | Should -Be 'agent:shipped' -Because 'the rest of the change merges'
            }
        }
        Assert-JourneyClean
    }

    It 'holds every path as a proposal when the allowlist is empty' {
        $saved = Get-OrchestratorSetting -Name WritablePaths
        try {
            Set-OrchestratorSetting -Name WritablePaths -Value @()
            $null = Invoke-BuildRound -Number 51 -Edits $script:Docs

            Get-FakePipelineLabel 51 | Should -Be 'human:approval' -Because (Get-JourneyStory 51)
            @(Get-FakeComments 51)[-1].Body | Should -Match '- `docs/decisions\.md`'
        } finally {
            Set-OrchestratorSetting -Name WritablePaths -Value $saved
        }
        Assert-JourneyClean
    }
}
