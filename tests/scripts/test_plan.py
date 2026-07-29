"""Tests for the Plan step (.github/scripts/kanban/Plan.ps1).

Covers the four business rules that must not regress:

1. Key-term extraction — stop-words filtered, short tokens dropped, dedup'd,
   capped at Top.
2. Out-of-scope overlap — headings whose text contains any key term are
   returned; misses return an empty array; missing file returns empty.
3. Blast-radius narrow detection — `At-risk: none` or `Recommendation: proceed`
   reads as narrow; an at-risk listing reads as wide. Missing report → narrow
   (no signal of widespread risk).
4. AFK / HITL heuristic — AFK only when narrow blast AND zero open questions;
   either signal flips to HITL.

Plan.ps1 is a module-internal library (ADR-013) — it carries no top-level
param() block and is not dot-sourced standalone. Each test imports the Kanban
module (which loads Config/GitHub/Plan and exports the functions) and then
exercises the exact functions the orchestrator calls. This avoids duplicating
logic into snippets that drift from the source.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
REPO_ROOT = Path(__file__).parent.parent.parent
MODULE = REPO_ROOT / ".github" / "scripts" / "kanban" / "Kanban.psd1"

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
    repo/default-branch without invoking gh/git, then import the Kanban module so
    the exported Plan functions are callable."""
    # -DisableNameChecking suppresses the benign "unapproved verbs" warning
    # (Acquire-/Release- etc.) that would otherwise pollute captured stdout and
    # break the exact-match assertions below.
    return (
        f"$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        f"$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
    )


# ── Get-PlanKeyTerms ──────────────────────────────────────────────────────────


def test_key_terms_filters_stop_words() -> None:
    """Stop words like `for`, `the`, `to` must NOT appear in the result."""
    script = (
        _import_prelude()
        + "$kt = Get-PlanKeyTerms -Title 'Add a new feature for the API' -Top 5\n"
        + "$kt -join ','\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    output = result.stdout.strip()
    for stop_word in ("for", "the", "a"):
        assert stop_word not in output.split(","), (
            f"Stop word {stop_word!r} should have been filtered, got: {output}"
        )


def test_key_terms_drops_short_tokens() -> None:
    """Tokens shorter than 3 chars must be dropped (too noisy for search)."""
    script = (
        _import_prelude()
        + "$kt = Get-PlanKeyTerms -Title 'AI ML API' -Top 5\n"
        + "$kt -join ','\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    tokens = result.stdout.strip().split(",") if result.stdout.strip() else []
    for t in tokens:
        if not t:
            continue
        assert len(t) >= 3, (
            f"Token {t!r} is shorter than 3 chars — must have been dropped"
        )


def test_key_terms_deduplicates() -> None:
    """Repeated tokens must appear at most once."""
    script = (
        _import_prelude()
        + "$kt = Get-PlanKeyTerms -Title 'planning planning planning workflow workflow' -Top 5\n"
        + "$kt -join ','\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    tokens = [t for t in result.stdout.strip().split(",") if t]
    assert tokens.count("planning") == 1, f"planning duplicated, got: {tokens}"
    assert tokens.count("workflow") == 1, f"workflow duplicated, got: {tokens}"


def test_key_terms_respects_top() -> None:
    """Caller-supplied Top must cap the result length."""
    script = (
        _import_prelude()
        + "$kt = Get-PlanKeyTerms -Title 'alpha beta gamma delta epsilon zeta eta theta' -Top 3\n"
        + "$kt.Count\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "3", (
        f"Top=3 should yield 3 tokens, got: {result.stdout!r}"
    )


# ── Find-OutOfScopeOverlap ────────────────────────────────────────────────────


def test_out_of_scope_overlap_finds_matching_heading(tmp_path: Path) -> None:
    """A key term contained in a `## ` heading must be reported as overlap."""
    oos = tmp_path / "out-of-scope.md"
    oos.write_text(
        "# Out of Scope\n\n## LangGraph orchestrator runtime\n\nText.\n\n## Some other thing\n\nText.\n",
        encoding="utf-8",
    )
    script = (
        _import_prelude()
        + f"$hits = Find-OutOfScopeOverlap -OutOfScopePath '{oos}' -KeyTerms @('langgraph')\n"
        + "$hits -join '|'\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert "LangGraph orchestrator runtime" in result.stdout, (
        f"Expected matching heading, got: {result.stdout!r}"
    )


def test_out_of_scope_overlap_no_match_returns_empty(tmp_path: Path) -> None:
    """No overlap → empty result, NOT an error."""
    oos = tmp_path / "out-of-scope.md"
    oos.write_text(
        "# Out of Scope\n\n## FastAPI in the starter\n\nText.\n", encoding="utf-8"
    )
    script = (
        _import_prelude()
        + f"$hits = Find-OutOfScopeOverlap -OutOfScopePath '{oos}' -KeyTerms @('streaming','tokens')\n"
        + "if ($hits.Count -eq 0) { 'EMPTY' } else { $hits -join '|' }\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "EMPTY", f"Expected EMPTY, got: {result.stdout!r}"


def test_out_of_scope_overlap_missing_file_returns_empty(tmp_path: Path) -> None:
    """A missing `.out-of-scope.md` must not throw — it returns empty."""
    missing = tmp_path / "does-not-exist.md"
    script = (
        _import_prelude()
        + f"$hits = Find-OutOfScopeOverlap -OutOfScopePath '{missing}' -KeyTerms @('anything')\n"
        + "if ($hits.Count -eq 0) { 'EMPTY' } else { 'NON-EMPTY' }\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "EMPTY", (
        f"Expected EMPTY for missing file, got: {result.stdout!r}"
    )


def test_out_of_scope_overlap_word_boundary(tmp_path: Path) -> None:
    """`plan` must NOT match `planet` — overlap uses word boundaries."""
    oos = tmp_path / "out-of-scope.md"
    oos.write_text(
        "# Out of Scope\n\n## Planet exploration robotics\n\nText.\n", encoding="utf-8"
    )
    script = (
        _import_prelude()
        + f"$hits = Find-OutOfScopeOverlap -OutOfScopePath '{oos}' -KeyTerms @('plan')\n"
        + "if ($hits.Count -eq 0) { 'EMPTY' } else { $hits -join '|' }\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "EMPTY", (
        f"`plan` should not match `planet` due to word boundary, got: {result.stdout!r}"
    )


# ── Test-NarrowBlast ──────────────────────────────────────────────────────────


def test_narrow_blast_recognises_at_risk_none() -> None:
    """`**At-risk:** none` must read as narrow."""
    script = (
        _import_prelude()
        + '$txt = "## Blast-Radius Report`n`n**At-risk:** none`n**Safe:** all"\n'
        + "Test-NarrowBlast -BlastText $txt\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "True", (
        f"Expected True for at-risk none, got: {result.stdout!r}"
    )


def test_narrow_blast_recognises_recommendation_proceed() -> None:
    """`**Recommendation:** proceed` must read as narrow."""
    script = (
        _import_prelude()
        + '$txt = "## Blast-Radius Report`n`n**Recommendation:** proceed"\n'
        + "Test-NarrowBlast -BlastText $txt\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "True", (
        f"Expected True for Recommendation=proceed, got: {result.stdout!r}"
    )


def test_narrow_blast_rejects_at_risk_listing() -> None:
    """An at-risk listing with a `refactor first` recommendation reads as wide."""
    script = (
        _import_prelude()
        + '$txt = "## Blast-Radius Report`n`n**At-risk:** main (fan-in=8)`n'
        + '**Recommendation:** refactor first — high fan-in modules detected"\n'
        + "Test-NarrowBlast -BlastText $txt\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "False", (
        f"Expected False for at-risk listing, got: {result.stdout!r}"
    )


def test_narrow_blast_missing_report_is_narrow() -> None:
    """An absent blast-radius report → narrow (no signal of widespread risk)."""
    script = _import_prelude() + "Test-NarrowBlast -BlastText ''\n"
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "True", (
        f"Expected True for missing report, got: {result.stdout!r}"
    )


# ── Get-PlanLabel ─────────────────────────────────────────────────────────────


def test_get_plan_label_narrow_zero_open_is_afk() -> None:
    script = (
        _import_prelude() + "Get-PlanLabel -NarrowBlast $true -OpenQuestionCount 0\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "AFK"


def test_get_plan_label_narrow_with_open_questions_is_hitl() -> None:
    """Open questions force HITL even when the blast is narrow."""
    script = (
        _import_prelude() + "Get-PlanLabel -NarrowBlast $true -OpenQuestionCount 2\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "HITL", (
        f"Expected HITL when open questions > 0, got: {result.stdout!r}"
    )


def test_get_plan_label_wide_blast_is_hitl() -> None:
    """Wide blast forces HITL even with zero open questions."""
    script = (
        _import_prelude() + "Get-PlanLabel -NarrowBlast $false -OpenQuestionCount 0\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "HITL", (
        f"Expected HITL for wide blast, got: {result.stdout!r}"
    )


def test_get_plan_label_wide_with_open_questions_is_hitl() -> None:
    script = (
        _import_prelude() + "Get-PlanLabel -NarrowBlast $false -OpenQuestionCount 5\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "HITL"


# ── Format-ChildIssue ────────────────────────────────────────────────────────
# Validates the block format matches what sync-issues.ps1 expects when parsing
# ISSUE: ... END_ISSUE blocks (LABELS: / ESTIMATE: / PRIORITY: header lines
# followed by **Goal**/**Description**/**Requirements**/**Acceptance Criteria**).


def test_format_child_issue_header_fields_appear_first() -> None:
    """LABELS / ESTIMATE / PRIORITY must come before **Goal** so sync-issues.ps1
    parses them as header fields, not body content."""
    script = (
        _import_prelude()
        + "$body = Format-ChildIssue -Label 'AFK' -Estimate 2 -Priority 'P3' "
        + "-Goal 'Goal text' -Description 'Description text' "
        + "-Requirements @('r1','r2') -AcceptanceCriteria @('a1','a2')\n"
        + "$body\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    body = result.stdout
    labels_idx = body.find("LABELS: AFK")
    estimate_idx = body.find("ESTIMATE: 2")
    priority_idx = body.find("PRIORITY: P3")
    goal_idx = body.find("**Goal**")
    assert 0 <= labels_idx < goal_idx, "LABELS must precede **Goal**"
    assert 0 <= estimate_idx < goal_idx, "ESTIMATE must precede **Goal**"
    assert 0 <= priority_idx < goal_idx, "PRIORITY must precede **Goal**"


def test_format_child_issue_numbers_requirements() -> None:
    """Requirements must be numbered starting at 1."""
    script = (
        _import_prelude()
        + "$body = Format-ChildIssue -Label 'AFK' -Goal 'g' -Description 'd' "
        + "-Requirements @('alpha','beta','gamma') -AcceptanceCriteria @()\n"
        + "$body\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    body = result.stdout
    assert "1. alpha" in body, body
    assert "2. beta" in body, body
    assert "3. gamma" in body, body


def test_format_child_issue_uses_checkboxes_for_acceptance() -> None:
    """Acceptance criteria render as `- [ ]` checkboxes."""
    script = (
        _import_prelude()
        + "$body = Format-ChildIssue -Label 'AFK' -Goal 'g' -Description 'd' "
        + "-Requirements @() -AcceptanceCriteria @('CI passes','tests green')\n"
        + "$body\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    body = result.stdout
    assert "- [ ] CI passes" in body, body
    assert "- [ ] tests green" in body, body


def test_format_child_issue_omits_estimate_when_zero() -> None:
    """Estimate=0 means `not set` — the line must NOT appear."""
    script = (
        _import_prelude()
        + "$body = Format-ChildIssue -Label 'HITL' -Estimate 0 -Goal 'g' -Description 'd' "
        + "-Requirements @() -AcceptanceCriteria @()\n"
        + "$body\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    assert "ESTIMATE:" not in result.stdout, "Estimate=0 must not emit ESTIMATE: line"


# ── PRD section ──────────────────────────────────────────────────────────────


def test_format_prd_section_contains_required_headings() -> None:
    """All six Lean PRD sections from plan/SKILL.md must appear in the output."""
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
        + "Format-PRDSection -Prd $prd\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    body = result.stdout
    for heading in (
        "**Problem Statement**",
        "**User Stories**",
        "**Tracer Bullet**",
        "**Implementation Decisions**",
        "**Testing Decisions**",
        "**Out of Scope**",
    ):
        assert heading in body, f"PRD section missing heading {heading!r}"


def test_format_prd_section_uses_agent_prd_markers() -> None:
    """Body section must be bounded by AGENT-PRD markers so it is regex-
    replaceable independently of AGENT-STATE / AGENT-BRIEF blocks."""
    script = (
        _import_prelude()
        + "$prd = [pscustomobject]@{ problem_statement='X.'; user_stories=@(); "
        + "tracer_bullet='T'; implementation_decisions=@(); testing_decisions=@(); "
        + "out_of_scope=@() }\n"
        + "Format-PRDSection -Prd $prd\n"
    )
    result = _ps(script)
    assert result.returncode == 0, result.stderr
    body = result.stdout
    assert "<!-- AGENT-PRD:BEGIN -->" in body
    assert "<!-- AGENT-PRD:END -->" in body
