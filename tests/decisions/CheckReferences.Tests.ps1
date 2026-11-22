#Requires -Version 7.0
<#
    Decision table — check-references.ps1: every script a workflow or the Taskfile runs,
    every path an agent document cites and every orchestrator function it names exists.
    Each row writes one reference into a minimal repository and asserts the exit code and
    the line naming the stale reference — or that prose, placeholders and worked examples
    stay quiet, because a noisy gate gets switched off.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
    $script:Check = 'check-references.ps1'
    # The tree the check walks: a workflow, the Taskfile, AGENTS.md, CONTEXT.md, the tests
    # README, a skill and one orchestrator function.
    $script:Scaffold = @{
        '.github/orchestrator/lib/Fake.ps1' = "function Get-FakeContext { }`n"
        '.github/tasks/demo.ps1'            = "exit 0`n"
        '.github/workflows/ci.yml'          = "jobs:`n  demo:`n    steps:`n      - run: pwsh .github/tasks/demo.ps1`n"
        'Taskfile.yml'                      = "tasks:`n  demo:`n    cmds:`n      - pwsh .github/tasks/demo.ps1`n"
        'AGENTS.md'                         = "# Agents`n"
        'CONTEXT.md'                        = "# CONTEXT`n"
        'tests/README.md'                   = "# Tests`n"
        '.agents/skills/demo/SKILL.md'      = "# Demo`n"
        'docs/adr/.keep'                    = ''
        'src/.keep'                         = ''
    }
}

Describe 'Decision: check-references' {
    AfterEach { Remove-CheckRepo $script:root }

    It '<Case> — exit <Exit>' -ForEach @(
        @{ Case = 'every reference resolves'; Exit = 0
           Files = @{ 'AGENTS.md' = "See ``src/`` and [the skill](.agents/skills/demo/SKILL.md); ``Get-FakeContext`` hydrates the run context.`n" } }
        @{ Case = 'a workflow runs a script that is gone'; Exit = 1; Line = '.github/workflows/ci.yml: script does not exist — .github/tasks/gone.ps1'
           Files = @{ '.github/workflows/ci.yml' = "jobs:`n  demo:`n    steps:`n      - run: pwsh .github/tasks/gone.ps1`n" } }
        @{ Case = 'the Taskfile runs a script that is gone'; Exit = 1; Line = 'Taskfile.yml: script does not exist — src/tools/gone.py'
           Files = @{ 'Taskfile.yml' = "tasks:`n  demo:`n    cmds:`n      - uv run python src/tools/gone.py`n" } }
        @{ Case = 'a workflow runs checks by a pattern'; Exit = 0
           Files = @{ '.github/workflows/ci.yml' = "jobs:`n  checks:`n    steps:`n      - run: Get-ChildItem .github/checks -Filter 'check-*.ps1'`n" } }
        @{ Case = 'a document cites a path that is gone'; Exit = 1; Line = 'AGENTS.md: path does not exist — .github/scripts/kanban/'
           Files = @{ 'AGENTS.md' = "The library lives in ``.github/scripts/kanban/``.`n" } }
        @{ Case = 'a document links a file that is gone'; Exit = 1; Line = 'AGENTS.md: path does not exist — .agents/skills/gone/REFERENCE.md'
           Files = @{ 'AGENTS.md' = "[reference](.agents/skills/gone/REFERENCE.md)`n" } }
        @{ Case = 'a document names a function that is gone'; Exit = 1; Line = 'AGENTS.md: function does not exist — Get-BogusFunction'
           Files = @{ 'AGENTS.md' = "Uses ``Get-BogusFunction`` to hydrate the run context.`n" } }
        @{ Case = 'prose with slashes';            Exit = 0; Files = @{ 'AGENTS.md' = "Prose mentioning ``Planner/Generator/Evaluator`` and ``CI/CD``.`n" } }
        @{ Case = 'a media type';                  Exit = 0; Files = @{ 'AGENTS.md' = "Prose mentioning ``text/event-stream`` inline.`n" } }
        @{ Case = 'an angle-bracket placeholder';  Exit = 0; Files = @{ 'AGENTS.md' = "Prose mentioning ``src/<domain>/`` inline.`n" } }
        @{ Case = 'a glob placeholder';            Exit = 0; Files = @{ 'AGENTS.md' = "Prose mentioning ``src/utils/m_*.py`` inline.`n" } }
        @{ Case = 'a naming template';             Exit = 0; Files = @{ 'AGENTS.md' = "Prose mentioning ``docs/adr/ADR-NNN-kebab-title.md`` inline.`n" } }
        @{ Case = 'a URL';                         Exit = 0; Files = @{ 'AGENTS.md' = "Prose mentioning ``https://example.com/docs/thing.md`` inline.`n" } }
        @{ Case = 'a command with flags and a media type'; Exit = 0
           Files = @{ 'AGENTS.md' = "Conducted via ``Invoke-Orchestration -From refine``; media type ``text/event-stream``.`n" } }
        @{ Case = 'CONTEXT.md names a core cmdlet'; Exit = 0; Files = @{ 'CONTEXT.md' = "Each task runnable calls ``Import-Module``.`n" } }
        @{ Case = 'a worked example names fictional files and functions'; Exit = 0
           Files = @{ '.agents/skills/demo/EXAMPLES.md' = "The agent creates ``src/payments/__init__.py`` and calls ``Invoke-FictionalStage``.`n" } }
    ) {
        $script:root = New-CheckRepo -Check $script:Check -Files $script:Scaffold, $Files -NoGit

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be $Exit -Because $run.Output
        if ($Line) { $run.Output | Should -Match ([regex]::Escape($Line)) }
    }

    It 'says what to change on every failure line' {
        $script:root = New-CheckRepo -Check $script:Check -Files $script:Scaffold, @{ 'AGENTS.md' = "See ``.github/gone/`` and ``Get-BogusFunction``.`n" } -NoGit

        $run = Invoke-CheckScript -Root $script:root -Check $script:Check

        $run.Exit | Should -Be 1
        $failures = @($run.Lines | Where-Object { $_ -match 'does not exist' })
        $failures.Count | Should -Be 2
        @($failures | Where-Object { $_ -notmatch ' — (fix|name) ' }) | Should -BeNullOrEmpty
    }
}
