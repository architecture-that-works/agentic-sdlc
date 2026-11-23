#Requires -Version 7.0
<#
    Refine journeys — an issue the owner opened, from its first run to agent:backlog,
    human:decision or agent:failed: a reply that settles the questions or leaves one
    open, a body reshaped to the issue template, an epic split into child issues, a
    plan proposing paths outside the writable ones, the questioning's tools and turn
    budget, and the outsider's issue. Enters only through Invoke-Orchestration
    (-From refine | comment) and asserts what the owner sees: the label, the comments,
    the sections of the issue body and the issues created.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Journey.ps1')
}

Describe 'Refine journey' {
    BeforeEach { $script:repo = Start-Journey -Name "Refine: $($____Pester.CurrentTest.Name)" }
    AfterEach { Stop-Journey $script:repo }

    It 'refines, plans and queues an issue with nothing open' {
        Add-FakeIssue -Number 7 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        Add-EngineResult -Task Refine -Reply (New-GrillReply)
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 7 -From refine

        Get-FakePipelineLabel 7 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 7)
        $body = (Get-FakeIssue 7).Body
        $body | Should -Match '## Agent Brief'
        $body | Should -Match '## Architecture Impact'
        $body | Should -Match '## Implementation Plan'
        $headings = Get-FakeCommentHeadings 7
        $headings | Should -Contain '· refined — open_questions=0'
        $headings | Should -Contain '· architected — blast-radius impact written to issue body'
        $headings | Should -Contain '· planned — implementation plan written to issue body'
        $headings[-1] | Should -BeLike '🤖✅ Ready — refined, architected and planned*'
        @($headings | Where-Object { $_ -like '🤖❌*' -or $_ -like '🤖⚠️*' }) | Should -BeNullOrEmpty
        Get-RemoteBranches $repo | Should -Be @('main')
        Assert-JourneyClean
    }

    It 'puts an issue on the board it states, with the estimate and priority refine gives it' {
        Set-JourneyBoard
        Add-FakeIssue -Number 11 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        # With a board, refine first asks for the estimate and the priority the item lacks.
        Add-EngineResult -Task Refine -Reply (@{ body = (New-IssueBody); estimate = 3; priority = 'P2' } | ConvertTo-Json -Compress)
        Add-EngineResult -Task Refine -Reply (New-GrillReply)
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 11 -From refine

        Get-FakePipelineLabel 11 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 11)
        $item = Get-FakeBoardItem 11
        $item | Should -Not -BeNullOrEmpty -Because 'refine adds an issue opened outside sync to the board'
        $item.status   | Should -Be 'Backlog'
        $item.estimate | Should -Be 3
        $item.priority | Should -Be 'P2'
        Assert-JourneyClean
    }

    It 'asks the owner, records the answer from a comment, and queues the issue' {
        Add-FakeIssue -Number 8 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        $question = [ordered]@{
            text = 'Greet by first name or full name?'; raised_by = 'self-grill-subagent'
            decision = 'First name — because it reads friendlier'
            alternatives = @('Full name — formal', 'Whatever the visitor typed — no parsing')
        }
        Add-EngineResult -Task Refine -Reply (New-GrillReply -Open @($question))
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 8 -From refine

        Get-FakePipelineLabel 8 | Should -Be 'human:decision' -Because (Get-JourneyStory 8)
        (Get-FakeCommentHeadings 8)[-1] | Should -Be '🤖⏸ Needs your decision — 1 question(s) before this can be built:'
        (Get-FakeIssue 8).Body | Should -Match '### Waiting on you'

        # The owner answers in a plain comment; the comment entry point takes it from there.
        Add-FakeComment -Issue 8 -Body 'ok'
        Add-EngineResult -Task Refine -Reply '{"answers":[{"id":1,"status":"answered","decision":"Greet by first name."}],"new_questions":[]}'
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 8 -From comment

        Get-FakePipelineLabel 8 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 8)
        $body = (Get-FakeIssue 8).Body
        $body | Should -Match '### Decided'
        $body | Should -Match 'Greet by first name or full name\? → Greet by first name\.'
        $body | Should -Not -Match '### Waiting on you'
        (Get-FakeCommentHeadings 8)[-1] | Should -BeLike '🤖✅ Ready — refined, architected and planned*'
        Assert-JourneyClean
    }

    It 'answers a reply that leaves a question open with a follow-up, and keeps the issue at human:decision' {
        Add-FakeIssue -Number 11 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        $first = [ordered]@{
            text = 'Greet by first name or full name?'; raised_by = 'self-grill-subagent'
            decision = 'First name — because it reads friendlier'
            alternatives = @('Full name — formal', 'Whatever the visitor typed — no parsing')
        }
        $second = [ordered]@{
            text = 'What does a visitor without a name see?'; raised_by = 'self-grill-subagent'
            decision = 'The greeting of today — because nothing changes for them'
            alternatives = @('A prompt to give a name — one more step', 'An error — strict')
        }
        Add-EngineResult -Task Refine -Reply (New-GrillReply -Open @($first, $second))
        Add-EngineResult -Task Plan -Reply (New-PlanReply)
        $null = Invoke-Orchestration -IssueNumber 11 -From refine
        (Get-FakeCommentHeadings 11)[-1] | Should -Be '🤖⏸ Needs your decision — 2 question(s) before this can be built:' -Because (Get-JourneyStory 11)

        # The owner settles the first question only; the answer check asks again for the second.
        Add-FakeComment -Issue 11 -Body '1A. Not sure about the second one yet.'
        $followUp = 'Pick B (a prompt to give a name) or C (an error), or keep A.'
        Add-EngineResult -Task Refine -Reply ([ordered]@{
            answers       = @(
                [ordered]@{ id = 1; status = 'answered'; decision = 'Greet by first name.' }
                [ordered]@{ id = 2; status = 'open'; follow_up = $followUp }
            )
            new_questions = @()
        } | ConvertTo-Json -Depth 4 -Compress)

        $null = Invoke-Orchestration -IssueNumber 11 -From comment

        Get-FakePipelineLabel 11 | Should -Be 'human:decision' -Because (Get-JourneyStory 11)
        (Get-FakeCommentHeadings 11)[-1] | Should -Be '🤖⏸ Thanks — 1 answer(s) recorded. Still needed:'
        $ask = (Get-FakeComments 11)[-1].Body
        $ask | Should -Match ([regex]::Escape($second.text))
        $ask | Should -Match ([regex]::Escape($followUp))
        $ask | Should -Not -Match ([regex]::Escape($first.text))
        $body = (Get-FakeIssue 11).Body
        $body | Should -Match '### Waiting on you'
        $body | Should -Match 'Greet by first name or full name\? → Greet by first name\.'
        # Nothing new to plan while a question is open: the plan ran once, on the first pass.
        @(Get-FakeEngineCalls -Task Plan).Count | Should -Be 1
        Assert-JourneyClean
    }

    It 'brings an issue body without the template''s headings into the template''s shape' {
        Add-FakeIssue -Number 12 -Title 'Greet the visitor by name' -Body 'Visitors should be greeted by name on the home page.'
        $shaped = New-TemplateBody -Text 'Visitors are greeted by name on the home page.'
        Add-EngineResult -Task Refine -Reply ([ordered]@{ body = $shaped; estimate = $null; priority = $null } | ConvertTo-Json -Compress)
        Add-EngineResult -Task Refine -Reply (New-GrillReply)
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 12 -From refine

        Get-FakePipelineLabel 12 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 12)
        $body = (Get-FakeIssue 12).Body
        foreach ($name in @(Get-IssueHeadings).Name) { $body | Should -Match ([regex]::Escape("**$name**:")) }
        $body | Should -Not -Match 'Visitors should be greeted by name on the home page\.'
        $body | Should -Match '## Agent Brief'
        Get-FakeCommentHeadings 12 | Should -Contain '· refined — body structured, open_questions=0'
        # The rewrite is asked for against the template itself.
        $rewrite = @(Get-FakeEngineCalls -Task Refine | Where-Object Label -eq 'Refine body')
        $rewrite.Count | Should -Be 1
        foreach ($name in @(Get-IssueHeadings).Name) { $rewrite[0].Prompt | Should -Match ([regex]::Escape("**$name**")) }
        Assert-JourneyClean
    }

    It 'splits an issue estimated as an epic into child issues written in the template''s shape' {
        $threshold = Get-OrchestratorSetting -Name DecomposeThreshold
        Add-FakeIssue -Number 13 -Title 'Greet visitors on every page' -Body (New-IssueBody) -Estimate $threshold -Priority 'P2'
        # An unrelated open issue: the duplicate search before each child must not match it.
        Add-FakeIssue -Number 20 -Title 'Export the report as a spreadsheet' -Body 'The monthly report can be downloaded.'
        Add-EngineResult -Task Refine -Reply (New-GrillReply)
        $children = @('Greet by name on the home page', 'Greet by name on the about page', 'Greet by name on the contact page')
        Add-EngineResult -Task Plan -Reply ([ordered]@{
            problem_statement        = 'Visitors want to be greeted by name on every page.'
            user_stories             = @('As a visitor, I want to be greeted by name, so that the site feels personal.')
            tracer_bullet            = 'The home page greets a visitor by name.'
            implementation_decisions = @('The name is read from the query string.')
            testing_decisions        = @('One request per page.')
            out_of_scope             = @('Remembering a visitor — not asked for.')
            children                 = @($children | ForEach-Object {
                $title = $_
                $sections = [ordered]@{}
                foreach ($h in @(Get-IssueHeadings)) {
                    $sections[$h.Name] = if ($h.Style -eq 'inline') { "$title." } else { @("$title.") }
                }
                [ordered]@{ title = $title; label = ''; estimate = 2; priority = 'P3'; sections = $sections }
            })
        } | ConvertTo-Json -Depth 8 -Compress)

        $null = Invoke-Orchestration -IssueNumber 13 -From refine

        $headings = Get-FakeCommentHeadings 13
        $headings | Should -Contain '🤖 Plan — Lean PRD published' -Because (Get-JourneyStory 13)
        $headings | Should -Contain '🤖 Plan — decomposition complete'
        (Get-FakeIssue 13).Body | Should -Match '## Lean PRD'
        $created = @($global:FakeGitHub.Issues.Values | Where-Object { $_.Number -notin 13, 20 })
        @($created.Title) | Should -Be $children
        foreach ($child in $created) {
            foreach ($name in @(Get-IssueHeadings).Name) { $child.Body | Should -Match ([regex]::Escape("**$name**:")) }
            $child.Body | Should -Match 'Parent: #13'
            # A child carries no label: it is refined on open like any issue.
            Get-FakePipelineLabel $child.Number | Should -BeNullOrEmpty
        }
        # No implementation plan of its own: the children are the plan.
        (Get-FakeIssue 13).Body | Should -Not -Match '## Implementation Plan'
        # Today's behaviour, not a settled rule: the split parent is still queued, so implement
        # would run on the epic as well as on its children. Whether the parent should instead be
        # held or closed is an open follow-up (raised under "Issues discovered" on #410); if the
        # orchestrator changes, update this line rather than read its failure as a regression.
        Get-FakePipelineLabel 13 | Should -Be 'agent:backlog'
        Assert-JourneyClean
    }

    It 'posts the proposal note for a plan outside the writable paths, and still queues the issue' {
        $outside = '.github/workflows/afk.yml'
        @(Get-OrchestratorSetting -Name WritablePaths | Where-Object { $outside -like $_ }) | Should -BeNullOrEmpty -Because "the journey needs a path outside WritablePaths"
        Add-FakeIssue -Number 14 -Title 'Run the pipeline on a schedule' -Body (New-IssueBody)
        Add-EngineResult -Task Refine -Reply (New-GrillReply)
        Add-EngineResult -Task Plan -Reply (New-PlanReply -Paths @('src/main.py', $outside))

        $null = Invoke-Orchestration -IssueNumber 14 -From refine

        Get-FakePipelineLabel 14 | Should -Be 'agent:backlog' -Because (Get-JourneyStory 14)
        $headings = Get-FakeCommentHeadings 14
        $headings | Should -Contain '🤖 Proposal — this plan changes files outside the agent write allowlist'
        @($headings | Where-Object { $_ -like '🤖⏸*' }) | Should -BeNullOrEmpty
        $note = @(Get-FakeComments 14 | Where-Object { $_.Body -like '🤖 Proposal*' })[0].Body
        $note | Should -Match ([regex]::Escape("- ``$outside``"))
        $note | Should -Not -Match 'src/main\.py'
        @((Get-CarrierState 14).proposed_paths) | Should -Be @($outside)
        Assert-JourneyClean
    }

    It 'questions with read-only tools on the refine turn budget' {
        Add-FakeIssue -Number 15 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        Add-EngineResult -Task Refine -Reply (New-GrillReply)
        Add-EngineResult -Task Plan -Reply (New-PlanReply)

        $null = Invoke-Orchestration -IssueNumber 15 -From refine

        $grill = @(Get-FakeEngineCalls -Task Refine | Where-Object Label -eq 'Self-grill')
        $grill.Count | Should -Be 1 -Because (Get-JourneyStory 15)
        $grill[0].Tools | Should -Be @('Read', 'Glob', 'Grep')
        $grill[0].MaxTurns | Should -Be (Get-OrchestratorSetting -Name MaxTurns_Refine)
        Assert-JourneyClean
    }

    It 'reports a questioning that ends on its turn budget, and hands the issue over after the attempts' {
        $retries = Get-OrchestratorSetting -Name MaxRetries
        $turns   = Get-OrchestratorSetting -Name MaxTurns_Refine
        Add-FakeIssue -Number 16 -Title 'Greet the visitor by name' -Body (New-IssueBody)
        foreach ($i in 1..$retries) { Add-EngineResult -Task Refine -Outcome max_turns -Reply 'Still reading the handlers…' }

        $null = Invoke-Orchestration -IssueNumber 16 -From refine

        Get-FakePipelineLabel 16 | Should -Be 'agent:failed' -Because (Get-JourneyStory 16)
        @(Get-FakeCommentHeadings 16)[-1] | Should -BeLike "🤖❌ Refine failed after $retries attempts at refine*"
        (Get-FakeComments 16)[-1].Body | Should -Match ([regex]::Escape("turn budget ($turns turn(s))"))
        $body = (Get-FakeIssue 16).Body
        $body | Should -Match '## Attempts'
        ([regex]::Matches($body, '\*\*Attempt \d+/\d+\*\* · refine · [^\n]*turn budget')).Count | Should -Be $retries
        $body | Should -Not -Match '## Agent Brief'
        Get-FakeEngineCalls -Task Plan | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'starts nothing for an issue whose author is not trusted' {
        Add-FakeIssue -Number 9 -Title 'Please add my feature' -Body (New-IssueBody) -AuthorAssociation 'NONE'

        $null = Invoke-Orchestration -IssueNumber 9 -From refine

        Get-FakePipelineLabel 9 | Should -BeNullOrEmpty
        Get-FakeComments 9 | Should -BeNullOrEmpty
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Get-FakeTransitions | Should -BeNullOrEmpty
        Assert-JourneyClean
    }

    It 'answers an owner comment on an untrusted issue with a noise line, and starts nothing' {
        Add-FakeIssue -Number 10 -Title 'Please add my feature' -Body (New-IssueBody) -AuthorAssociation 'CONTRIBUTOR'
        Add-FakeComment -Issue 10 -Body 'Looks useful — can the pipeline take this?'

        $null = Invoke-Orchestration -IssueNumber 10 -From comment

        Get-FakePipelineLabel 10 | Should -BeNullOrEmpty
        (Get-FakeCommentHeadings 10) | Should -Be @('· not processed — opened by an outside contributor; open your own issue to adopt it')
        Get-FakeEngineCalls | Should -BeNullOrEmpty
        Assert-JourneyClean
    }
}
