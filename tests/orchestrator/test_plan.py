"""Tests for the Plan stage (.github/orchestrator/stages/Plan.ps1).

Covers the four business rules that must not regress:

1. Key-term extraction — stop-words filtered, short tokens dropped, dedup'd,
   capped at Top.
2. Out-of-scope overlap — headings whose text contains any key term are
   returned; misses return an empty array; missing file returns empty.
3. Blast-radius narrow detection — `At-risk: none` or `Recommendation: proceed`
   reads as narrow; an at-risk listing reads as wide. Missing report → narrow
   (no signal of widespread risk).
4. Labelling heuristic — empty label only when narrow blast AND zero open questions;
   either signal flips to human:decision.

Plan.ps1 is a module-internal library (ADR-013) — it carries no top-level
param() block and is not dot-sourced standalone. Each test group imports the
orchestrator module ONCE per pwsh spawn and exercises all scenarios for a given
function family in that single process, cutting cold-start overhead from one
import per assertion to one import per family (~6 total).
"""

import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
REPO_ROOT = Path(__file__).parent.parent.parent
MODULE = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)


def _ps(script: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    """Run a PowerShell snippet; never propagate $KanbanRepo lookups by isolating
    via the GITHUB_* env vars set in the snippet itself when needed."""
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        cwd=str(cwd) if cwd else None,
        check=False,
    )


def _import_prelude() -> str:
    """Set GITHUB_REPOSITORY + GITHUB_DEFAULT_BRANCH so Config.ps1 resolves the
    repo/default-branch without invoking gh/git, then run the body inside the module's own session state.

    The functions exercised below (Get-KeyTerms,
    Format-PrdSection, …) are *internal* to the module: ADR-015 declares an
    explicit FunctionsToExport listing only the ~17 functions called from outside,
    so they are correctly private and not reachable via Import-Module. Widening
    the public API to satisfy tests is how an export list decays back to '*'.

    `& (Get-Module Orchestrator) { ... }` is PowerShell's documented way to execute
    inside a module's session state, so the body sees both the private functions and
    the module-scoped variables they read ($KanbanPrdBeginMarker and friends).
    Dot-sourcing was tried and does not work: a .psm1 does not populate the caller's
    scope, and sourcing Plan.ps1 alone resolves the functions but not their data.

    Each call site closes the block by appending "}" (see `_ps(script + "}\n")`).
    """
    return (
        f"$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        f"$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        f"& (Get-Module Orchestrator) {{\n"
    )


def _parse_cases(stdout: str) -> dict[str, str]:
    """Extract tagged results from a batched pwsh script.

    Supports two output forms written by the PowerShell script:
    - ``__CASE__key=value`` — single-line scalar result.
    - ``__BEGIN__key`` / ``__END__key`` — multi-line block; lines between the
      markers are joined with newlines and stored under *key*.
    """
    cases: dict[str, str] = {}
    current_key: str | None = None
    current_lines: list[str] = []

    for line in stdout.splitlines():
        if current_key is not None:
            if line == f"__END__{current_key}":
                cases[current_key] = "\n".join(current_lines)
                current_key = None
                current_lines = []
            else:
                current_lines.append(line)
        elif line.startswith("__CASE__"):
            key, _, val = line[len("__CASE__") :].partition("=")
            cases[key] = val
        elif line.startswith("__BEGIN__"):
            current_key = line[len("__BEGIN__") :]
            current_lines = []

    return cases


# ── Get-PlanKeyTerms ──────────────────────────────────────────────────────────


def test_key_terms_batch() -> None:
    """All four Get-PlanKeyTerms invariants exercised in one pwsh spawn."""
    script = (
        _import_prelude()
        + "$r1 = Get-PlanKeyTerms -Title 'Add a new feature for the API' -Top 5\n"
        + "Write-Output \"__CASE__stop_words=$($r1 -join ',')\"\n"
        + "$r2 = Get-PlanKeyTerms -Title 'AI ML API' -Top 5\n"
        + "Write-Output \"__CASE__short_tokens=$($r2 -join ',')\"\n"
        + "$r3 = Get-PlanKeyTerms -Title 'planning planning planning workflow workflow' -Top 5\n"
        + "Write-Output \"__CASE__dedup=$($r3 -join ',')\"\n"
        + "$r4 = Get-PlanKeyTerms -Title 'alpha beta gamma delta epsilon zeta eta theta' -Top 3\n"
        + 'Write-Output "__CASE__top_cap=$($r4.Count)"\n'
    )
    result = _ps(script + "}\n")
    assert result.returncode == 0, result.stderr
    cases = _parse_cases(result.stdout)

    # stop-word filter: for / the / a must not appear
    tokens = [t for t in cases.get("stop_words", "").split(",") if t]
    for stop in ("for", "the", "a"):
        assert stop not in tokens, (
            f"Stop word {stop!r} should have been filtered, got: {tokens}"
        )

    # short-token filter: every returned token must be ≥3 chars
    tokens = [t for t in cases.get("short_tokens", "").split(",") if t]
    for t in tokens:
        assert len(t) >= 3, (
            f"Token {t!r} is shorter than 3 chars — must have been dropped"
        )

    # deduplication: repeated inputs appear at most once
    tokens = [t for t in cases.get("dedup", "").split(",") if t]
    assert tokens.count("planning") == 1, f"planning duplicated, got: {tokens}"
    assert tokens.count("workflow") == 1, f"workflow duplicated, got: {tokens}"

    # Top cap: result length must not exceed -Top
    assert cases.get("top_cap", "").strip() == "3", (
        f"Top=3 should yield 3 tokens, got: {cases.get('top_cap')!r}"
    )


# ── Find-OutOfScopeOverlap ────────────────────────────────────────────────────


def test_out_of_scope_overlap_batch(tmp_path: Path) -> None:
    """All four Find-OutOfScopeOverlap invariants exercised in one pwsh spawn."""
    oos_found = tmp_path / "oos_found.md"
    oos_found.write_text(
        "# Out of Scope\n\n"
        "## LangGraph orchestrator runtime\n\nText.\n\n"
        "## Some other thing\n\nText.\n",
        encoding="utf-8",
    )
    oos_no_match = tmp_path / "oos_no_match.md"
    oos_no_match.write_text(
        "# Out of Scope\n\n## FastAPI in the starter\n\nText.\n",
        encoding="utf-8",
    )
    oos_word_boundary = tmp_path / "oos_word_boundary.md"
    oos_word_boundary.write_text(
        "# Out of Scope\n\n## Planet exploration robotics\n\nText.\n",
        encoding="utf-8",
    )
    missing = tmp_path / "does-not-exist.md"

    script = (
        _import_prelude()
        + f"$h1 = Find-OutOfScopeOverlap -OutOfScopePath '{oos_found}'"
        + " -KeyTerms @('langgraph')\n"
        + "Write-Output \"__CASE__found=$($h1 -join '|')\"\n"
        + f"$h2 = Find-OutOfScopeOverlap -OutOfScopePath '{oos_no_match}'"
        + " -KeyTerms @('streaming','tokens')\n"
        + 'Write-Output "__CASE__no_match=$($h2.Count)"\n'
        + f"$h3 = Find-OutOfScopeOverlap -OutOfScopePath '{missing}'"
        + " -KeyTerms @('anything')\n"
        + 'Write-Output "__CASE__missing=$($h3.Count)"\n'
        + f"$h4 = Find-OutOfScopeOverlap -OutOfScopePath '{oos_word_boundary}'"
        + " -KeyTerms @('plan')\n"
        + 'Write-Output "__CASE__word_boundary=$($h4.Count)"\n'
    )
    result = _ps(script + "}\n")
    assert result.returncode == 0, result.stderr
    cases = _parse_cases(result.stdout)

    # matching heading must be returned
    assert "LangGraph orchestrator runtime" in cases.get("found", ""), (
        f"Expected matching heading, got: {cases.get('found')!r}"
    )
    # no overlap → empty result, NOT an error
    assert cases.get("no_match", "1").strip() == "0", (
        f"Expected empty result, got count: {cases.get('no_match')!r}"
    )
    # missing file → empty, NOT a throw
    assert cases.get("missing", "1").strip() == "0", (
        f"Missing file must return empty, got count: {cases.get('missing')!r}"
    )
    # `plan` must NOT match `planet` — word boundary enforcement
    assert cases.get("word_boundary", "1").strip() == "0", (
        f"`plan` should not match `planet` due to word boundary, "
        f"got count: {cases.get('word_boundary')!r}"
    )


# ── Test-NarrowBlast ──────────────────────────────────────────────────────────


def test_narrow_blast_batch() -> None:
    """All four Test-NarrowBlast invariants exercised in one pwsh spawn."""
    script = (
        _import_prelude()
        + '$t1 = "## Blast-Radius Report`n`n**At-risk:** none`n**Safe:** all"\n'
        + 'Write-Output "__CASE__at_risk_none=$(Test-NarrowBlast -BlastText $t1)"\n'
        + '$t2 = "## Blast-Radius Report`n`n**Recommendation:** proceed"\n'
        + 'Write-Output "__CASE__rec_proceed=$(Test-NarrowBlast -BlastText $t2)"\n'
        + '$t3 = "## Blast-Radius Report`n`n**At-risk:** main (fan-in=8)`n'
        + '**Recommendation:** refactor first — high fan-in modules detected"\n'
        + 'Write-Output "__CASE__at_risk_listing=$(Test-NarrowBlast -BlastText $t3)"\n'
        + "Write-Output \"__CASE__empty_blast=$(Test-NarrowBlast -BlastText '')\"\n"
    )
    result = _ps(script + "}\n")
    assert result.returncode == 0, result.stderr
    cases = _parse_cases(result.stdout)

    assert cases.get("at_risk_none", "").strip() == "True", (
        f"Expected True for at-risk none, got: {cases.get('at_risk_none')!r}"
    )
    assert cases.get("rec_proceed", "").strip() == "True", (
        f"Expected True for Recommendation=proceed, got: {cases.get('rec_proceed')!r}"
    )
    assert cases.get("at_risk_listing", "").strip() == "False", (
        f"Expected False for at-risk listing, got: {cases.get('at_risk_listing')!r}"
    )
    assert cases.get("empty_blast", "").strip() == "True", (
        f"Expected True for missing report, got: {cases.get('empty_blast')!r}"
    )


# ── Get-PlanLabel ─────────────────────────────────────────────────────────────


def test_get_plan_label_batch() -> None:
    """All four Get-PlanLabel invariants exercised in one pwsh spawn."""
    script = (
        _import_prelude()
        + 'Write-Output "__CASE__narrow_zero='
        + '$(Get-PlanLabel -NarrowBlast $true -OpenQuestionCount 0)"\n'
        + 'Write-Output "__CASE__narrow_open='
        + '$(Get-PlanLabel -NarrowBlast $true -OpenQuestionCount 2)"\n'
        + 'Write-Output "__CASE__wide_zero='
        + '$(Get-PlanLabel -NarrowBlast $false -OpenQuestionCount 0)"\n'
        + 'Write-Output "__CASE__wide_open='
        + '$(Get-PlanLabel -NarrowBlast $false -OpenQuestionCount 5)"\n'
    )
    result = _ps(script + "}\n")
    assert result.returncode == 0, result.stderr
    cases = _parse_cases(result.stdout)

    assert cases.get("narrow_zero", "").strip() == "", (
        f"narrow blast + zero open questions should be empty, "
        f"got: {cases.get('narrow_zero')!r}"
    )
    assert cases.get("narrow_open", "").strip() == "human:decision", (
        f"Open questions force human:decision even when blast is narrow, "
        f"got: {cases.get('narrow_open')!r}"
    )
    assert cases.get("wide_zero", "").strip() == "human:decision", (
        f"Wide blast forces human:decision even with zero open questions, "
        f"got: {cases.get('wide_zero')!r}"
    )
    assert cases.get("wide_open", "").strip() == "human:decision", (
        f"Wide blast + open questions should be human:decision, got: {cases.get('wide_open')!r}"
    )


# ── Format-ChildIssue ────────────────────────────────────────────────────────
# Validates the block format matches what sync.ps1 expects when parsing
# ISSUE: ... END_ISSUE blocks (LABELS: / ESTIMATE: / PRIORITY: header lines
# followed by one section per issue-template heading). The template is stubbed
# under tmp_path so no heading is spelled here from memory (#369).

_CHILD_TEMPLATE = (
    "---\nname: Stub\nabout: Stub\n---\n"
    "**Aim**: <text>\n**Steps**:\n1. <step>\n**Done when**:\n- [ ] <check>\n"
)


def test_format_child_issue_batch(tmp_path: Path) -> None:
    """Format-ChildIssue invariants exercised in one pwsh spawn."""
    template = tmp_path / ".github" / "ISSUE_TEMPLATE" / "issue.md"
    template.parent.mkdir(parents=True)
    template.write_text(_CHILD_TEMPLATE, encoding="utf-8")
    script = (
        _import_prelude()
        + f"$script:_Root = '{tmp_path}'\n"
        # Scenario 1: LABELS / ESTIMATE / PRIORITY must precede the first heading
        + "$b1 = Format-ChildIssue -Label 'human:decision' -Estimate 2 -Priority 'P3' "
        + "-Sections @{ 'Aim' = 'Aim text'; 'Steps' = @('r1','r2'); 'Done when' = @('a1') }\n"
        + '$b1s = $b1 -join "`n"\n'
        + "Write-Output \"__CASE__labels_idx=$($b1s.IndexOf('LABELS: human:decision'))\"\n"
        + "Write-Output \"__CASE__estimate_idx=$($b1s.IndexOf('ESTIMATE: 2'))\"\n"
        + "Write-Output \"__CASE__priority_idx=$($b1s.IndexOf('PRIORITY: P3'))\"\n"
        + "Write-Output \"__CASE__aim_idx=$($b1s.IndexOf('**Aim**: Aim text'))\"\n"
        + "Write-Output \"__CASE__steps_idx=$($b1s.IndexOf('**Steps**:'))\"\n"
        + "Write-Output \"__CASE__done_idx=$($b1s.IndexOf('**Done when**:'))\"\n"
        # Scenario 2: a numbered heading numbers its items from 1
        + "$b2 = Format-ChildIssue -Sections @{ 'Steps' = @('alpha','beta','gamma') }\n"
        + '$b2s = $b2 -join "`n"\n'
        + "Write-Output \"__CASE__req_1=$(($b2s -match '1\\. alpha'))\"\n"
        + "Write-Output \"__CASE__req_2=$(($b2s -match '2\\. beta'))\"\n"
        + "Write-Output \"__CASE__req_3=$(($b2s -match '3\\. gamma'))\"\n"
        # Scenario 3: a checkbox heading renders `- [ ]` items
        + "$b3 = Format-ChildIssue -Sections ([pscustomobject]@{ 'Done when' = @('CI passes','tests green') })\n"
        + '$b3s = $b3 -join "`n"\n'
        + "Write-Output \"__CASE__ckbox_ci=$(($b3s -match '- \\[ \\] CI passes'))\"\n"
        + "Write-Output \"__CASE__ckbox_green=$(($b3s -match '- \\[ \\] tests green'))\"\n"
        # Scenario 4: Estimate=0 means not set — ESTIMATE: line must not appear;
        # an absent value gets a placeholder in its heading's style
        + "$b4 = Format-ChildIssue -Label 'human:decision' -Estimate 0 -Sections @{}\n"
        + '$b4s = $b4 -join "`n"\n'
        + "Write-Output \"__CASE__no_estimate=$(($b4s -match 'ESTIMATE:'))\"\n"
        + "Write-Output \"__CASE__ph_steps=$(($b4s -match '1\\. _\\(populated by plan synthesis\\)_'))\"\n"
    )
    result = _ps(script + "}\n")
    assert result.returncode == 0, result.stderr
    cases = _parse_cases(result.stdout)

    # header ordering, then the template's headings in template order
    labels_idx = int(cases.get("labels_idx", "-1"))
    estimate_idx = int(cases.get("estimate_idx", "-1"))
    priority_idx = int(cases.get("priority_idx", "-1"))
    aim_idx = int(cases.get("aim_idx", "-1"))
    steps_idx = int(cases.get("steps_idx", "-1"))
    done_idx = int(cases.get("done_idx", "-1"))
    assert 0 <= labels_idx < aim_idx, (labels_idx, aim_idx)
    assert 0 <= estimate_idx < aim_idx, (estimate_idx, aim_idx)
    assert 0 <= priority_idx < aim_idx, (priority_idx, aim_idx)
    assert aim_idx < steps_idx < done_idx, (aim_idx, steps_idx, done_idx)

    # numbered list
    assert cases.get("req_1", "").strip() == "True", "item '1. alpha' missing"
    assert cases.get("req_2", "").strip() == "True", "item '2. beta' missing"
    assert cases.get("req_3", "").strip() == "True", "item '3. gamma' missing"

    # checkboxes
    assert cases.get("ckbox_ci", "").strip() == "True", "'- [ ] CI passes' missing"
    assert cases.get("ckbox_green", "").strip() == "True", "'- [ ] tests green' missing"

    # no ESTIMATE line when Estimate=0; placeholder in the numbered style
    assert cases.get("no_estimate", "").strip() == "False", (
        "Estimate=0 must not emit ESTIMATE: line"
    )
    assert cases.get("ph_steps", "").strip() == "True", "numbered placeholder missing"


# ── Format-PRDSection ────────────────────────────────────────────────────────


def test_format_prd_section_batch() -> None:
    """Both Format-PRDSection invariants (required headings + AGENT-PRD markers)
    exercised in one pwsh spawn."""
    script = (
        _import_prelude()
        + "$prd = [pscustomobject]@{\n"
        + "    problem_statement = 'Users need X.'\n"
        + "    user_stories      = @('As a user I want A','As a user I want B')\n"
        + "    tracer_bullet     = 'narrow vertical slice'\n"
        + "    implementation_decisions = @('schema X','contract Y')\n"
        + "    testing_decisions = @('unit on module M')\n"
        + "    out_of_scope      = @('multi-tenant — deferred because Y')\n"
        + "}\n"
        + "Write-Output '__BEGIN__prd'\n"
        + "Format-PRDSection -Prd $prd\n"
        + "Write-Output '__END__prd'\n"
    )
    result = _ps(script + "}\n")
    assert result.returncode == 0, result.stderr
    cases = _parse_cases(result.stdout)
    body = cases.get("prd", "")

    # all six Lean PRD sections from plan/SKILL.md must appear
    for heading in (
        "**Problem Statement**",
        "**User Stories**",
        "**Tracer Bullet**",
        "**Implementation Decisions**",
        "**Testing Decisions**",
        "**Out of Scope**",
    ):
        assert heading in body, f"PRD section missing heading {heading!r}"

    # body must be bounded by AGENT-PRD markers for regex-replaceable updates
    assert "<!-- AGENT-PRD:BEGIN -->" in body, "Missing AGENT-PRD:BEGIN marker"
    assert "<!-- AGENT-PRD:END -->" in body, "Missing AGENT-PRD:END marker"
