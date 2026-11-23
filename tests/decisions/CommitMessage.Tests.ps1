#Requires -Version 7.0
<#
    Decision table — the commit message: what Get-CommitMessage (engines/Claude.ps1)
    makes of the engine's replies. It removes trailer lines itself, checks the rest
    against the commit-message rules, asks once more naming the broken rule, and uses
    the fallback when the second reply breaks a rule too or a call fails. The fallback
    meets the rules as well. The first line is also the pull request's title.

    The generator runs for real against the stand-in CLI (tests/fakes/Cli.ps1), in the
    module's scope. Each row scripts the replies and asserts the message, whether the
    engine wrote it (FromEngine), and how many times the CLI was started.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')

    function Invoke-CommitMessage {
        param([int]$Number = 42, [string]$Title = 'Keep the settings tolerant')
        return & (Get-Module Orchestrator) { param($n, $t) Get-CommitMessage -Diff 'diff --git a/x b/x' -Number $n -Title $t } $Number $Title
    }
    function New-Reply { param([string]$Text) return @{ Result = @{ subtype = 'success'; result = $Text } } }
}

Describe 'Decision: the commit message' {
    BeforeEach { $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" -RealEngine }
    AfterEach {
        Remove-FakeCli
        Stop-Journey $script:repo
    }

    It '<Case>' -ForEach @(
        @{ Case = 'a reply that meets the rules is used as it is'; Starts = 1; FromEngine = $true
           Replies = @("fix(#42): ignore unknown settings`n`nSettings() raised on an unknown variable.")
           Message = "fix(#42): ignore unknown settings`n`nSettings() raised on an unknown variable." }
        @{ Case = 'a reply with a Co-Authored-By line comes back without it'; Starts = 1; FromEngine = $true
           Replies = @("fix(#42): ignore unknown settings`n`nco-authored-by: Someone <s@example.com>`nSigned-off-by: Someone <s@example.com>")
           Message = 'fix(#42): ignore unknown settings' }
        @{ Case = 'a first line over 72 characters is asked again and the second reply is used'; Starts = 2; FromEngine = $true
           Replies = @("fix(#42): $('x' * 70)", 'fix(#42): ignore unknown settings')
           Message = 'fix(#42): ignore unknown settings' }
        @{ Case = 'a reply in a markdown fence is asked again'; Starts = 2; FromEngine = $true
           Replies = @("```````nfix(#42): ignore unknown settings`n``````", 'fix(#42): ignore unknown settings')
           Message = 'fix(#42): ignore unknown settings' }
        @{ Case = 'a scope that is not the issue number is asked again'; Starts = 2; FromEngine = $true
           Replies = @('fix(config): ignore unknown settings', 'fix(#42): ignore unknown settings')
           Message = 'fix(#42): ignore unknown settings' }
        @{ Case = 'two replies that break a rule give the fallback'; Starts = 2; FromEngine = $false
           Replies = @('fix(#42): ignore unknown settings.', 'chore: tidy')
           Message = 'feat(#42): Keep the settings tolerant' }
    ) {
        $null = New-FakeCli -Attempts @($Replies | ForEach-Object { New-Reply $_ })
        Install-FakeCli

        $result = Invoke-CommitMessage

        $result.Message | Should -Be $Message
        $result.FromEngine | Should -Be $FromEngine
        @(Get-FakeCliCalls).Count | Should -Be $Starts
    }

    It 'the follow-up names the broken rule (the 72-character limit)' {
        $null = New-FakeCli -Attempts @((New-Reply "fix(#42): $('x' * 70)"), (New-Reply 'fix(#42): ignore unknown settings'))
        Install-FakeCli

        $null = Invoke-CommitMessage

        $calls = @(Get-FakeCliCalls)
        $calls[0].Prompt | Should -Match 'at most 72 characters'
        $calls[0].Prompt | Should -Not -Match 'previous reply broke'
        $calls[1].Prompt | Should -Match 'previous reply broke this rule: The whole first line is at most 72 characters'
    }

    It 'a failed call gives the fallback, without asking again' {
        $null = New-FakeCli -Attempts @(@{ Throw = "The term 'claude' is not recognized" })
        Install-FakeCli

        $result = Invoke-CommitMessage

        $result.Message | Should -Be 'feat(#42): Keep the settings tolerant'
        $result.FromEngine | Should -BeFalse
        @(Get-FakeCliCalls).Count | Should -Be 1
    }

    It 'the fallback for a long issue title is cut at a word to fit in 72 characters, and meets the rules' {
        $null = New-FakeCli -Attempts @(@{ Lines = @('boom'); Exit = 1 })
        Install-FakeCli
        $title = 'Keep one commit-message generator, used by the orchestrator and its eval.'

        $result = Invoke-CommitMessage -Number 417 -Title $title

        $result.FromEngine | Should -BeFalse
        $result.Message | Should -Be 'feat(#417): Keep one commit-message generator, used by the orchestrator'
        $result.Message.Length | Should -BeLessOrEqual 72
        & (Get-Module Orchestrator) { param($m) Get-CommitRuleBroken -Message $m -Number 417 } $result.Message | Should -BeNullOrEmpty
    }
}
