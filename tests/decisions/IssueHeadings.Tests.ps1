#Requires -Version 7.0
<#
    Decision table — the headings an issue template gives every issue, and how each
    section is written (its style), read by Get-IssueHeadings from
    .github/ISSUE_TEMPLATE/issue.md: refine's body check, the epic's child issues and
    sync's block check all take them from there. One row per template; each row writes
    the template into a temporary repository and asserts the headings in order, or the
    error that names the file.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../journeys/Journey.ps1')

    function New-TemplateRoot {
        param($Template)
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "headings-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root '.github/ISSUE_TEMPLATE')
        if ($null -ne $Template) { Set-Content -LiteralPath (Join-Path $root '.github/ISSUE_TEMPLATE/issue.md') -Value $Template -Encoding utf8NoBOM -NoNewline }
        return $root
    }
}

Describe 'Decision: the issue template''s headings' {
    AfterEach { if ($script:root) { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue } }

    It '<Case>' -ForEach @(
        @{
            Case     = 'front matter is skipped; each style is read from the line after the heading'
            Template = "---`nname: Change`nabout: x`n---`n`n**Goal**: One sentence.`n**Steps**:`n1. First.`n**Done when**:`n- [ ] Checked.`n**Notes**:`n- a note`n"
            Expected = 'Goal=inline; Steps=numbered; Done when=checkbox; Notes=bullet'
        }
        @{
            Case     = 'a template without front matter is read whole'
            Template = "**Goal**: One sentence.`n**Description**: Why.`n"
            Expected = 'Goal=inline; Description=inline'
        }
        @{
            Case     = 'a heading with neither text nor a list under it is inline'
            Template = "**Goal**:`n**Description**: Why.`n"
            Expected = 'Goal=inline; Description=inline'
        }
        @{
            Case     = 'a ticked checkbox and Windows line ends still read as a checkbox'
            Template = "**Goal**: x`r`n**Acceptance Criteria**:`r`n- [x] done`r`n"
            Expected = 'Goal=inline; Acceptance Criteria=checkbox'
        }
    ) {
        $script:root = New-TemplateRoot -Template $Template

        $headings = @(Get-IssueHeadings -Root $script:root)

        (($headings | ForEach-Object { "$($_.Name)=$($_.Style)" }) -join '; ') | Should -Be $Expected
    }

    It 'stops, naming the file, when <Case>' -ForEach @(
        @{ Case = 'the template is missing';        Template = $null;                         Message = '*issue template .github/ISSUE_TEMPLATE/issue.md is missing*' }
        @{ Case = 'the template holds no heading';  Template = "---`nname: x`n---`nJust prose.`n"; Message = '*issue template .github/ISSUE_TEMPLATE/issue.md holds no heading*' }
    ) {
        $script:root = New-TemplateRoot -Template $Template

        { Get-IssueHeadings -Root $script:root } | Should -Throw $Message
    }

    It 'this repository''s template asks for a goal, a description, numbered requirements and checkbox criteria' {
        $script:root = $null

        $headings = @(Get-IssueHeadings)

        (($headings | ForEach-Object { "$($_.Name)=$($_.Style)" }) -join '; ') |
            Should -Be 'Goal=inline; Description=inline; Requirements=numbered; Acceptance Criteria=checkbox'
    }
}
