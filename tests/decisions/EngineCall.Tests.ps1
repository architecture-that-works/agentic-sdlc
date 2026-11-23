#Requires -Version 7.0
<#
    Decision table — the engine call: how Invoke-EngineTask (engines/Claude.ps1) starts
    the Claude CLI, how it reads the way a run ended (finished, out of turns, failed —
    retried or not), and what it reports the run did (the reply, the checked answer, the
    tools called, the edits the engine refused).

    Every journey replaces this function with the fake engine, so here it runs for real
    against the stand-in CLI (tests/fakes/Cli.ps1), entered at the seam itself
    (Invoke-EngineAtSeam). Each row scripts what the CLI prints and asserts the command
    line it was started with, how many times, the back-off between starts, and the
    returned object. The model a task runs on is the model table's (ModelTier.Tests.ps1).
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')
}

Describe 'Decision: the engine call' {
    BeforeEach { $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" -RealEngine }
    AfterEach {
        Remove-FakeCli
        Stop-Journey $script:repo
    }

    Context 'how the CLI is started' {
        It 'an agentic call names the model, the tools twice, the turn budget and the schema' {
            $null = New-FakeCli -Attempts @(@{ Lines = @(New-CliResult @{ subtype = 'success'; result = 'done'; structured_output = @{} }) })
            Install-FakeCli

            $run = Invoke-EngineAtSeam @{ Task = 'Review'; Prompt = 'look at this'; Label = 'Review'; Tools = @('Read', 'Glob', 'Grep'); MaxTurns = 35; Schema = '{"type":"object"}' }

            @(Get-FakeCliCalls).Count | Should -Be 1
            $call = (Get-FakeCliCalls)[0]
            $call.Argv[0] | Should -Be '-p'
            Get-FakeCliFlag $call '--model' | Should -Not -BeNullOrEmpty
            Get-FakeCliFlag $call '--tools' | Should -Be 'Read,Glob,Grep'
            Get-FakeCliFlag $call '--allowedTools' | Should -Be 'Read,Glob,Grep'
            Get-FakeCliFlag $call '--max-turns' | Should -Be '35'
            Get-FakeCliFlag $call '--json-schema' | Should -Be '{"type":"object"}'
            Get-FakeCliFlag $call '--output-format' | Should -Be 'stream-json'
            $call.Argv | Should -Contain '--verbose'
            $call.Prompt | Should -Be 'look at this'
            $run.Outcome | Should -Be 'finished'
            $run.Reply | Should -Be 'done'
        }

        It 'a one-shot call starts with no tools, no turn budget and no schema' {
            $null = New-FakeCli -Attempts @(@{ Lines = @(New-CliResult @{ subtype = 'success'; result = 'feat: x' }) })
            Install-FakeCli

            $run = Invoke-EngineAtSeam @{ Task = 'CommitMessage'; Prompt = 'diff'; Label = 'Commit message' }

            $call = (Get-FakeCliCalls)[0]
            Get-FakeCliFlag $call '--tools' | Should -Be ''
            $call.Argv | Should -Not -Contain '--allowedTools'
            $call.Argv | Should -Not -Contain '--max-turns'
            $call.Argv | Should -Not -Contain '--json-schema'
            $run.Reply | Should -Be 'feat: x'
            $run.Answer | Should -BeNullOrEmpty
        }

        It 'refuses <Case> before the CLI starts' -ForEach @(
            @{ Case = 'tools without a turn budget'; Arguments = @{ Tools = @('Read') };                 Message = '*-Tools and -MaxTurns come together*' }
            @{ Case = 'a turn budget without tools'; Arguments = @{ MaxTurns = 5 };                      Message = '*-Tools and -MaxTurns come together*' }
            @{ Case = 'a turn budget of 0';          Arguments = @{ Tools = @('Read'); MaxTurns = 0 };  Message = '*-MaxTurns must be a positive turn budget*' }
        ) {
            $null = New-FakeCli
            Install-FakeCli

            { Invoke-EngineAtSeam (@{ Task = 'Review'; Prompt = 'p'; Label = 'Review' } + $Arguments) } | Should -Throw $Message

            Get-FakeCliCalls | Should -BeNullOrEmpty
        }
    }

    Context 'how a run ends' {
        It '<Case>: <Outcome> after <Starts> start(s)' -ForEach @(
            @{ Case = 'a successful run'; Outcome = 'finished'; Starts = 1; Sleeps = @(); Cause = $null
               Attempts = @(@{ Result = @{ subtype = 'success'; result = 'done' } }) }
            @{ Case = 'a run that ends on its turn budget'; Outcome = 'max_turns'; Starts = 1; Sleeps = @(); Cause = '*ran out of turns (30)*'
               Attempts = @(@{ Result = @{ subtype = 'error_max_turns'; is_error = $true }; Exit = 1 }) }
            @{ Case = 'a failed start, then an answer'; Outcome = 'finished'; Starts = 2; Sleeps = @(20); Cause = $null
               Attempts = @(@{ Lines = @('API Error: 529 overloaded'); Exit = 1 }, @{ Result = @{ subtype = 'success'; result = 'done' } }) }
            @{ Case = 'a CLI that keeps failing'; Outcome = 'failed'; Starts = 3; Sleeps = @(20, 40); Cause = '*exited 1 after 3 attempt(s)*'
               Attempts = @(@{ Lines = @('boom'); Exit = 1 }) }
            @{ Case = 'a spent usage allowance'; Outcome = 'failed'; Starts = 1; Sleeps = @(); Cause = '*usage limit*'
               Attempts = @(@{ Result = @{ subtype = 'success'; is_error = $true; result = 'Claude AI usage limit reached|1900000000' }; Exit = 1 }) }
            @{ Case = 'a CLI that cannot start'; Outcome = 'failed'; Starts = 1; Sleeps = @(); Cause = '*the engine CLI could not run*'
               Attempts = @(@{ Throw = "The term 'claude' is not recognized" }) }
            @{ Case = 'a run that gives no result'; Outcome = 'failed'; Starts = 1; Sleeps = @(); Cause = '*the engine gave no result*'
               Attempts = @(@{ Lines = @('just prose'); Exit = 0 }) }
        ) {
            $null = New-FakeCli -Attempts $Attempts
            Install-FakeCli

            $run = Invoke-EngineAtSeam @{ Task = 'Review'; Prompt = 'p'; Label = 'Review'; Tools = @('Read'); MaxTurns = 30 }

            $run.Outcome | Should -Be $Outcome -Because "$($run.Cause)"
            @(Get-FakeCliCalls).Count | Should -Be $Starts
            @(Get-FakeCliSleeps) | Should -Be $Sleeps
            if ($Cause) { $run.Cause | Should -BeLike $Cause } else { $run.Cause | Should -BeNullOrEmpty }
        }

        It 'a call that keeps failing keeps what the CLI printed' {
            $null = New-FakeCli -Attempts @(@{ Lines = @('boom'); Exit = 1 })
            Install-FakeCli

            $run = Invoke-EngineAtSeam @{ Task = 'Plan'; Prompt = 'p'; Label = 'Plan' }

            $run.Output | Should -Match 'boom'
        }

        It 'a call for a checked answer fails once when <Case>' -ForEach @(
            @{ Case = 'the result holds no answer'; Exit = 0; Cause = '*no structured_output*'
               Event = @{ subtype = 'success'; result = 'APPROVED' } }
            @{ Case = 'the engine gave up on the answer'; Exit = 1; Cause = '*error_max_structured_output_retries*'
               Event = @{ subtype = 'error_max_structured_output_retries'; is_error = $true } }
        ) {
            $null = New-FakeCli -Attempts @(@{ Result = $Event; Exit = $Exit })
            Install-FakeCli

            $run = Invoke-EngineAtSeam @{ Task = 'Review'; Prompt = 'p'; Label = 'Review'; Tools = @('Read'); MaxTurns = 30; Schema = '{}' }

            $run.Outcome | Should -Be 'failed'
            $run.Cause | Should -BeLike $Cause
            @(Get-FakeCliCalls).Count | Should -Be 1
            $run.Answer | Should -BeNullOrEmpty
        }
    }

    Context 'what the run did' {
        It 'reports the refused file edits, repo-relative, and no refused command' {
            $denials = @(
                @{ tool_name = 'Bash'; tool_input = @{ command = 'rm -rf .claude' } }
                @{ tool_name = 'Edit'; tool_input = @{ file_path = (Join-Path (Get-Location).ProviderPath '.devcontainer/x.json') } }
                @{ tool_name = 'Write'; tool_input = @{ file_path = '.mcp.json' } }
                @{ tool_name = 'NotebookEdit'; tool_input = @{ notebook_path = './nb.ipynb' } }
                @{ tool_name = 'Edit'; tool_input = @{ file_path = '.mcp.json' } }
            )
            $null = New-FakeCli -Attempts @(@{ Lines = @(New-CliResult @{ subtype = 'success'; result = 'done'; permission_denials = $denials }) })
            Install-FakeCli

            $run = Invoke-EngineAtSeam @{ Task = 'ImplementSmall'; Prompt = 'p'; Label = 'Implement'; Tools = @('Edit'); MaxTurns = 5 }

            @($run.RefusedEdits) | Should -Be @('.devcontainer/x.json', '.mcp.json', 'nb.ipynb')
        }

        It 'reports no refused edit when the run has no result' {
            $null = New-FakeCli -Attempts @(@{ Lines = @(); Exit = 0 })
            Install-FakeCli

            $run = Invoke-EngineAtSeam @{ Task = 'ImplementSmall'; Prompt = 'p'; Label = 'Implement'; Tools = @('Edit'); MaxTurns = 5 }

            @($run.RefusedEdits) | Should -BeNullOrEmpty
        }

        It 'passes each tool call to the caller as it streams, without the engine''s own answer tool' {
            $null = New-FakeCli -Attempts @(@{ Lines = @(
                (@{ type = 'system'; subtype = 'init' } | ConvertTo-Json -Compress)
                (New-CliAssistant @(@{ type = 'text'; text = 'Reading first.' }, (New-CliToolUse Read @{ file_path = 'AGENTS.md' }), (New-CliToolUse Bash @{ command = 'uv run pytest' })))
                (New-CliAssistant @((New-CliToolUse StructuredOutput @{ verdict = 'approved' })))
                (New-CliResult @{ subtype = 'success'; structured_output = @{ verdict = 'x' } })
            ) })
            Install-FakeCli
            $global:EngineCallSeen = [System.Collections.Generic.List[string]]::new()

            $run = Invoke-EngineAtSeam @{ Task = 'Review'; Prompt = 'p'; Label = 'Review'; Tools = @('Read', 'Bash'); MaxTurns = 5; Schema = '{}'
                OnToolCall = { param($call) $global:EngineCallSeen.Add("$($call.Name)=$($call.Input.file_path)$($call.Input.command)"); 'ignored output' } }

            @($run.ToolsCalled) | Should -Be @('Read', 'Bash')
            @($global:EngineCallSeen) | Should -Be @('Read=AGENTS.md', 'Bash=uv run pytest')
            $run.Answer.verdict | Should -Be 'x'
        }

        It 'drops the CLI''s workspace-trust noise from what it printed, and keeps a real warning' {
            $null = New-FakeCli -Attempts @(@{ Lines = @(
                'Warning: permissions.allow entries are ignored on an untrusted workspace'
                'set hasTrustDialogAccepted to trust it'
                'a real warning'
                (New-CliResult @{ subtype = 'success'; result = 'feat: y' })
            ) })
            Install-FakeCli

            $run = Invoke-EngineAtSeam @{ Task = 'CommitMessage'; Prompt = 'p'; Label = 'Commit' }

            $run.Output | Should -Not -Match 'permissions\.allow|hasTrustDialogAccepted'
            $run.Output | Should -Match 'a real warning'
            $run.Reply | Should -Be 'feat: y'
        }
    }
}
