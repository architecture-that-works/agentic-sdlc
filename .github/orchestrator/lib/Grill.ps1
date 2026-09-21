#Requires -Version 7.0
<#
.SYNOPSIS
    Self-grill subagent library — exposes Invoke-Grill. Dot-source-safe.

.DESCRIPTION
    Function library for the `refine` skill's AFK alignment phase. Defines
    Invoke-Grill and its helpers with NO top-level param() block, so dot-sourcing
    it (from implement.ps1 / Invoke-Refine, or the grill.ps1 CLI wrapper) only
    registers functions and never pollutes or clobbers the caller's scope
    (see ADR-013). The standalone CLI lives in grill.ps1.

    Rules 1-4 from refine/SKILL.md are enforced by the system prompt below:
        1. Codebase first — read before asking
        2. Always recommend — every question carries the agent's position
        3. No branch left open — partial resolution is not resolution
        4. Interface before implementation — no file paths or line numbers

.NOTES
    Tracked in: https://github.com/ysuurme/my_template_repo/issues/85
    Schema:    src/utils/m_planning.py::GrillResult
    Skill:     .agents/skills/refine/SKILL.md § AFK invocation pattern
#>

# ── Grill-Me system prompt (Rules 1-4 from refine/SKILL.md) ──────────────────

$GrillSystemPrompt = @'
You are the adversarial Senior Architect from the `refine` skill running the
Grill-Me protocol against a single GitHub issue. You operate AFK — there is no
human in this loop. Your job is to surface every alignment risk hidden in the
issue body and resolve as many as you can from the codebase. The remainder
become explicit `HITL` decisions for a human.

You MUST obey these rules from .agents/skills/refine/SKILL.md:

  Rule 1 — CODEBASE FIRST. If a question can be answered by reading the code,
           read it. Never push a question to a human that the code already
           answers. Decided questions go in `decided_questions[]` with the
           file/symbol evidence summarised in `decision`.

  Rule 2 — ALWAYS RECOMMEND. Every open question must carry your recommended
           answer in the `decision` field, framed as "Recommend: <option> —
           because <reason>". A question without a recommendation is delegation,
           not grilling.

  Rule 3 — NO BRANCH LEFT OPEN. Walk every alternative for every decision. If
           you cannot pick between alternatives without human judgement (taste,
           policy, strategy, deadline trade-offs), the question is genuinely
           open and stays in `open_questions[]`.

  Rule 4 — INTERFACE BEFORE IMPLEMENTATION. The Agent Brief describes
           contracts, schemas, and event shapes. NEVER reference file paths,
           module names, or line numbers in the brief — those are volatile.

Tooling: you may read CONTEXT.md, AGENTS.md, docs/adr/, .agents/skills/, and
any src/ file. You must not write, edit, or commit anything — your only output
is a single JSON object printed on stdout. No prose, no Markdown fences.

Output schema (must validate against src/utils/m_planning.py::GrillResult):

{
  "agent_brief": {
    "feature_name":      "<short slug>",
    "problem_statement": "<one paragraph, user perspective>",
    "interfaces":        ["<contract 1>", "<contract 2>"],
    "constraints":       ["<ADR-NNN: ...>", "<invariant from CONTEXT.md>"],
    "out_of_scope":      ["<deferred concept>"],
    "tracer_bullet":     "<single narrowest vertical slice>"
  },
  "open_questions": [
    {
      "text":     "<the unresolved alignment question>",
      "raised_by":"self-grill-subagent",
      "decision": "Recommend: <option> — because <reason>"
    }
  ],
  "decided_questions": [
    {
      "text":      "<question the codebase answered>",
      "raised_by": "self-grill-subagent",
      "decided_by":"self-grill-subagent",
      "decision":  "<answer> — evidence: <symbol/file summary, no line numbers>"
    }
  ],
  "glossary_diffs": [
    { "term": "<X>", "definition": "<Y>", "disambiguation": "<Z or null>", "action": "add" }
  ]
}

If the issue body is fully specified and the codebase resolves every branch,
return an empty `open_questions[]` — that is the green light for AFK execution.
If even one decision genuinely needs human judgement, that question MUST appear
in `open_questions[]` so the orchestrator can spawn a `HITL` child issue.
'@

# ── Helpers ───────────────────────────────────────────────────────────────────

function Get-GrillUserPrompt {
    param([string]$Title, [string]$Body)
    @"
ISSUE TITLE: $Title

ISSUE BODY:
$Body

TASK:
1. Read CONTEXT.md, AGENTS.md, .agents/skills/refine/SKILL.md, the relevant
   ADRs, and the source files implied by the issue body.
2. For every architectural decision the issue raises, decide whether the
   codebase already resolves it. If yes, record it in decided_questions[].
   If no, record it in open_questions[] with your recommended position.
3. Write the Agent Brief in contract terms only — no file paths.
4. Print the JSON object and nothing else.
"@
}

function Resolve-GrillModel {
    param([string]$Requested)
    if ($Requested) { return $Requested }
    if ($env:KANBAN_MODEL_SONNET) { return $env:KANBAN_MODEL_SONNET }
    return 'claude-sonnet-4-6'
}

# Strips Markdown code fences from a Claude response. The subagent is told to
# emit raw JSON but Sonnet occasionally wraps it; trim defensively so the
# pydantic validator never sees fence garbage.
function ConvertFrom-ClaudeJsonResponse {
    param([string]$Raw)
    $text = $Raw.Trim()
    if ($text -match '(?s)```(?:json)?\s*(\{.+\})\s*```') {
        return $Matches[1]
    }
    return $text
}

function Test-GrillResultSchema {
    param([string]$Json)
    # Round-trip through the pydantic model so failures surface as the same
    # ValidationError messages Python callers would see. Returns the normalised
    # JSON on success, or $null on validation failure (caller logs and aborts).
    $tmpIn  = New-TemporaryFile
    $tmpOut = New-TemporaryFile
    try {
        $Json | Out-File $tmpIn.FullName -Encoding utf8
        $py = @"
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path('src').resolve().parent))
from src.utils.m_planning import GrillResult

data = json.loads(pathlib.Path(r'$($tmpIn.FullName)').read_text(encoding='utf-8'))
result = GrillResult.model_validate(data)
pathlib.Path(r'$($tmpOut.FullName)').write_text(
    result.model_dump_json(by_alias=True), encoding='utf-8'
)
"@
        $err = $py | uv run python - 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Error "GrillResult validation failed:`n$err"
            return $null
        }
        return (Get-Content $tmpOut.FullName -Raw).Trim()
    } finally {
        Remove-Item $tmpIn.FullName, $tmpOut.FullName -ErrorAction SilentlyContinue
    }
}

# ── Public entry point ───────────────────────────────────────────────────────

function Invoke-Grill {
    [CmdletBinding()]
    param(
        [int]   $Issue    = 0,
        [string]$Title    = '',
        [string]$Body     = '',
        [switch]$DryRun,
        [string]$Model    = '',
        [int]   $MaxTurns = 25
    )

    if ($Issue -gt 0) {
        $issueJson = gh issue view $Issue --json title,body 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "Could not fetch issue #${Issue} via gh: $($issueJson.Trim())"
        }
        $parsed = $issueJson | ConvertFrom-Json
        $Title  = $parsed.title
        $Body   = $parsed.body
    }
    if (-not $Title -or -not $Body) {
        throw "Invoke-Grill requires either -Issue or both -Title and -Body."
    }

    $userPrompt = Get-GrillUserPrompt -Title $Title -Body $Body
    $fullPrompt = "$GrillSystemPrompt`n`n---`n`n$userPrompt"

    if ($DryRun) {
        return [pscustomobject]@{
            mode        = 'dry-run'
            title       = $Title
            body_length = $Body.Length
            prompt      = $fullPrompt
        }
    }

    $resolvedModel = Resolve-GrillModel -Requested $Model

    # The subagent is read-only — restrict tools so it cannot accidentally write
    # to the working tree. The orchestrator alone owns mutations.
    $raw = $fullPrompt | claude `
        --model $resolvedModel `
        --allowedTools 'Read,Glob,Grep' `
        --max-turns   $MaxTurns 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Claude self-grill subagent exited with code ${LASTEXITCODE}:`n$raw"
    }

    $json = ConvertFrom-ClaudeJsonResponse -Raw $raw
    $validated = Test-GrillResultSchema -Json $json
    if (-not $validated) {
        throw "Self-grill subagent returned JSON that failed pydantic validation."
    }
    return ($validated | ConvertFrom-Json)
}
