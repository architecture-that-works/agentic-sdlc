#Requires -Version 7.0
<#
    Decision table — the engine's usage limit. First: which words the engine answers with
    are a spent allowance, and when the issue resumes (the reset time the message names,
    one hour when it names none, never more than MaxPauseHours). Each row enters through
    Invoke-Orchestration with the engine's check before the run answering those words, and
    asserts what the owner sees: agent:paused with the resume time in the carrier and the
    ⏳ comment, or a run that stops because the engine is not ready.

    Then: what Resume-PausedIssues (every run's first step, and the hourly check) does with
    a paused issue — resume it once its time has come and the engine answers again, or
    leave it paused.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')

    # The resume time the carrier of issue -Number holds, as UTC.
    function Get-PausedUntil {
        param([int]$Number)
        if ((Get-FakeIssue $Number).Body -notmatch '"paused_until":\s*"([^"]+)"') { return $null }
        return ([datetimeoffset]::Parse($Matches[1], [cultureinfo]::InvariantCulture)).UtcDateTime
    }

    # A planned issue's body whose carrier says it is paused until -Until (none: no time stored).
    function New-PausedBody {
        param([int]$Number, $Until = $null, [switch]$OpenQuestion)
        $body = New-PlannedIssueBody -Number $Number
        if ($Until) { $body = $body -replace '"open_questions"', "`"paused_until`": `"$($Until.ToString('o'))`", `"open_questions`"" }
        if ($OpenQuestion) {
            $body = $body -replace '"open_questions":\s*\[\s*\]', '"open_questions": [{"id": 1, "text": "First name or full name?", "raised_by": "self-grill-subagent"}]'
        }
        return $body
    }

    # "3pm" for the hour -At falls in (UTC).
    function Format-Hour {
        param([datetime]$At)
        $h = $At.Hour % 12
        if ($h -eq 0) { $h = 12 }
        return "$h$(if ($At.Hour -lt 12) { 'am' } else { 'pm' })"
    }
}

Describe 'Decision: the engine reports a spent allowance' {
    BeforeEach { $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" }
    AfterEach { Stop-Journey $script:repo }

    It '"<Kind>" pauses the issue until <Resume>' -ForEach @(
        @{ Kind = 'usage limit reached|<epoch in 2h>';   Resume = 'the epoch' }
        @{ Kind = 'limit reached · resets <hour>';       Resume = 'that hour' }
        @{ Kind = 'Usage limit reached. Resets at <hh:mm>'; Resume = 'that minute' }
        @{ Kind = 'your session limit resets <hour>';     Resume = 'that hour' }
        @{ Kind = "You've hit your team's limit · resets <hour>"; Resume = 'that hour' }
        @{ Kind = 'Claude AI usage limit reached';       Resume = 'an hour from now' }
        @{ Kind = "You've hit your monthly spend limit";  Resume = 'an hour from now' }
        @{ Kind = "You've hit your daily limit";          Resume = 'an hour from now' }
        @{ Kind = 'rate_limit_error';                    Resume = 'an hour from now' }
        @{ Kind = 'usage limit reached|<epoch in 20h>';  Resume = 'the longest pause' }
    ) {
        $now  = (Get-Date).ToUniversalTime()
        $hour = $now.AddHours(3)
        $at   = $now.AddMinutes(90)
        $text = $Kind.Replace('<epoch in 2h>', "$([DateTimeOffset]::new($now.AddHours(2)).ToUnixTimeSeconds())").
                      Replace('<epoch in 20h>', "$([DateTimeOffset]::new($now.AddHours(20)).ToUnixTimeSeconds())").
                      Replace('<hour>', (Format-Hour $hour)).Replace('<hh:mm>', $at.ToString('HH:mm'))
        $expected = switch ($Resume) {
            'the epoch'         { $now.AddHours(2) }
            'that hour'         { $hour.Date.AddHours($hour.Hour) }
            'that minute'       { $at.Date.AddHours($at.Hour).AddMinutes($at.Minute) }
            'an hour from now'  { $now.AddHours(1) }
            'the longest pause' { $now.AddHours((Get-OrchestratorSetting -Name MaxPauseHours)) }
        }
        Add-FakeIssue -Number 60 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 60) -Labels @('agent:backlog')
        Add-EngineResult -Task EngineCheck -Outcome failed -Output $text

        $null = Invoke-Orchestration -IssueNumber 60 -From implement

        Get-FakePipelineLabel 60 | Should -Be 'agent:paused' -Because (Get-JourneyStory 60)
        $until = Get-PausedUntil 60
        [math]::Abs(($until - $expected).TotalMinutes) | Should -BeLessOrEqual 1 -Because "the carrier says $($until.ToString('o')) for '$text'"
        $headings = @(Get-FakeCommentHeadings 60)
        $headings[-1] | Should -BeLike '🤖⏳ Paused — the Claude usage limit is reached. Work resumes after *'
        @($headings | Where-Object { $_ -like '🤖🔁*' }) | Should -BeNullOrEmpty -Because 'a pause counts no attempt'
        @(Get-FakeEngineCalls | Where-Object Task -ne 'EngineCheck') | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It '"<Text>" is not a usage limit: the run stops on an engine that is not ready' -ForEach @(
        @{ Text = 'Error: Invalid API key · Please run /login' }
        @{ Text = 'Could not hit your endpoint. Retrying later. Note: the request size limit is 10MB' }
        @{ Text = "The term 'claude' is not recognized" }
    ) {
        Add-FakeIssue -Number 61 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 61) -Labels @('agent:backlog')
        Add-EngineResult -Task EngineCheck -Outcome failed -Output $Text

        { Invoke-Orchestration -IssueNumber 61 -From implement } | Should -Throw '*authentication or execution failed*'

        Get-FakePipelineLabel 61 | Should -Be 'agent:backlog'
        Get-PausedUntil 61 | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'pauses a run whose stage failed while the allowance was spent, and counts no attempt' {
        Add-FakeIssue -Number 62 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 62) -Labels @('agent:backlog')
        Add-EngineResult -Task EngineCheck -Reply 'pong'
        Add-EngineResult -Task ImplementSmall -Outcome failed
        Add-EngineResult -Task EngineCheck -Outcome failed -Output 'Claude AI usage limit reached'

        $null = Invoke-Orchestration -IssueNumber 62 -From implement

        Get-FakePipelineLabel 62 | Should -Be 'agent:paused' -Because (Get-JourneyStory 62)
        @(Get-FakeCommentHeadings 62 | Where-Object { $_ -like '🤖🔁*' -or $_ -like '🤖❌ Failed*' }) | Should -BeNullOrEmpty
        (Get-FakeIssue 62).Body | Should -Not -Match '## Attempts' -Because 'a pause records no attempt'
        Assert-JourneyClean
    }
}

Describe 'Decision: a paused issue' {
    BeforeEach { $script:repo = Start-Journey -Name "Decision: $($____Pester.CurrentTest.Name)" }
    AfterEach { Stop-Journey $script:repo }

    It 'paused <When> is <Outcome>' -ForEach @(
        @{ When = 'until an hour ago';      Offset = -60;   Outcome = 'resumed at implement' }
        @{ When = 'with no time stored';    Offset = $null; Outcome = 'resumed at implement' }
        @{ When = 'until an hour from now'; Offset = 60;    Outcome = 'left paused' }
    ) {
        $until = if ($null -ne $Offset) { (Get-Date).ToUniversalTime().AddMinutes($Offset) } else { $null }
        Add-FakeIssue -Number 63 -Title 'Name the decisions' -Body (New-PausedBody -Number 63 -Until $until) -Labels @('agent:paused')

        Resume-PausedIssues

        if ($Outcome -eq 'left paused') {
            Get-FakePipelineLabel 63 | Should -Be 'agent:paused'
            Get-FakeCommentHeadings 63 | Should -BeNullOrEmpty
            Get-FakeEngineCalls | Should -BeNullOrEmpty -Because 'nothing is due, so the engine is not asked'
        } else {
            Get-FakePipelineLabel 63 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 63)
            # The resume posts only the restart's own comment.
            @(Get-FakeCommentHeadings 63) | Should -Be @('· restarting from implement (usage limit lifted)')
            Get-PausedUntil 63 | Should -BeNullOrEmpty
        }
        Assert-JourneyClean
    }

    It 'moves a due issue''s resume time to the new reset when the engine still refuses' {
        Add-FakeIssue -Number 64 -Title 'Name the decisions' -Body (New-PausedBody -Number 64 -Until (Get-Date).ToUniversalTime().AddMinutes(-5)) -Labels @('agent:paused')
        $reset = (Get-Date).ToUniversalTime().AddHours(2)
        Add-EngineResult -Task EngineCheck -Outcome failed -Output "Claude AI usage limit reached|$([DateTimeOffset]::new($reset).ToUnixTimeSeconds())"

        Resume-PausedIssues

        Get-FakePipelineLabel 64 | Should -Be 'agent:paused'
        [math]::Abs(((Get-PausedUntil 64) - $reset).TotalMinutes) | Should -BeLessOrEqual 1
        Get-FakeCommentHeadings 64 | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'sends a due issue with an open question back to refine' {
        Add-FakeIssue -Number 65 -Title 'Name the decisions' -Body (New-PausedBody -Number 65 -OpenQuestion) -Labels @('agent:paused')

        Resume-PausedIssues

        Get-FakePipelineLabel 65 | Should -BeNullOrEmpty
        @(Get-FakeCommentHeadings 65) | Should -Be @('· restarting refine (usage limit lifted)')
        @($global:FakeGitHub.Dispatches | ForEach-Object { "$($_.Workflow) $($_.Fields -join ' ')" }) | Should -Be @('afk.yml stage=refine issue_number=65')
        Assert-JourneyClean
    }

    It 'asks the engine nothing when no issue is paused' {
        Add-FakeIssue -Number 66 -Title 'Name the decisions' -Body (New-PlannedIssueBody -Number 66) -Labels @('agent:backlog')

        Resume-PausedIssues

        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Assert-JourneyClean
    }
}
