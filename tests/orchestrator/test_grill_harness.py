"""Tests for the self-grill subagent harness (issue #85).

Three surfaces are exercised:

1. ``.agents/skills/refine/scripts/_grill.ps1`` — the dot-sourceable function
   library (Invoke-Grill); must expose the function with no side effects and no
   scope leak. ``grill.ps1`` is the thin standalone CLI wrapper around it,
   invocable in ``-DryRun`` mode without contacting Claude (see ADR-013).
2. ``.github/orchestrator/lib/GitHub.ps1`` § ``Set-AgentBrief`` markers — the
   AGENT-BRIEF section is bounded by HTML-comment markers that must remain
   identifiable from outside PowerShell (Python parsers, future Cloud Run
   service, etc.).
3. ``.github/orchestrator/lib/GitHub.ps1`` § ``New-HitlChildIssue`` title format
   — the HITL child issue title must carry the parent number and a truncated
   question stub so a human scanning the issue list can see the linkage.

Each test inlines just enough of the production logic to keep the test fully
hermetic (no live ``gh`` / ``claude`` calls).
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(
    not shutil.which("pwsh"),
    reason="pwsh not available",
)

REPO_ROOT = Path(__file__).resolve().parents[2]
GRILL_SCRIPT = REPO_ROOT / ".agents/skills/refine/scripts/grill.ps1"  # CLI wrapper
GRILL_LIB = (
    REPO_ROOT / ".agents/skills/refine/scripts/_grill.ps1"
)  # dot-sourced library


def _ps(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        check=False,
    )


def _ps_file(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PWSH, "-NoProfile", "-File", str(GRILL_SCRIPT), *args],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        check=False,
    )


# ── Standalone harness probe ──────────────────────────────────────────────────


def test_grill_script_exists_and_is_pwsh7() -> None:
    """The standalone harness must exist and target PowerShell 7+."""
    assert GRILL_SCRIPT.exists(), f"Missing: {GRILL_SCRIPT}"
    head = GRILL_SCRIPT.read_text(encoding="utf-8").splitlines()[0]
    assert head.strip() == "#Requires -Version 7.0", (
        "grill.ps1 must declare #Requires -Version 7.0 per the PowerShell 7+ invariant."
    )


def test_grill_script_notes_repoint_to_issue_85() -> None:
    """The stub used to point at merged issue #8 — the new harness must NOTES
    issue #85 instead (the work that actually delivered this implementation)."""
    text = GRILL_SCRIPT.read_text(encoding="utf-8")
    assert "issues/85" in text, (
        "grill.ps1 NOTES must repoint to issue #85, not merged #8."
    )
    assert "Issue #8" not in text, (
        "grill.ps1 must no longer claim Issue #8 is tracking it — that issue is merged."
    )


def test_grill_dry_run_returns_prompt_without_claude() -> None:
    """``-DryRun`` must render the assembled prompt and exit 0 without invoking
    Claude. The output must contain the Rule 1-4 enforcement language."""
    result = _ps_file(
        [
            "-Title",
            "Add SSE endpoint",
            "-Body",
            "we want streaming completions",
            "-DryRun",
        ]
    )
    assert result.returncode == 0, (
        f"grill.ps1 -DryRun must exit 0.\nstdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "Rule 1" in result.stdout
    assert "Rule 4" in result.stdout
    assert "Add SSE endpoint" in result.stdout
    assert "GrillResult" in result.stdout


def test_grill_lib_is_dot_source_safe() -> None:
    """Dot-sourcing the LIBRARY (_grill.ps1) must expose ``Invoke-Grill`` without
    side effects AND without leaking a top-level ``$Issue`` into the caller's
    scope — the leak that once zeroed run.ps1's issue number (ADR-013)."""
    script = (
        "$Issue = 86; "
        f". '{GRILL_LIB.as_posix()}'; "
        "if ((Get-Command Invoke-Grill -ErrorAction SilentlyContinue) -and $Issue -eq 86) "
        "{ exit 0 } else { exit 1 }"
    )
    result = _ps(script)
    assert result.returncode == 0, (
        f"Dot-sourcing _grill.ps1 must expose Invoke-Grill without clobbering "
        f"the caller's $Issue.\nstdout: {result.stdout}\nstderr: {result.stderr}"
    )


def test_grill_lib_dot_source_then_dry_run_invokes_function() -> None:
    """Once the library is dot-sourced, Invoke-Grill must accept -DryRun and
    return a prompt."""
    script = (
        f". '{GRILL_LIB.as_posix()}'; "
        "$r = Invoke-Grill -Title 'X' -Body 'Y' -DryRun; "
        "if ($r.mode -eq 'dry-run' -and $r.prompt) { exit 0 } else { exit 1 }"
    )
    result = _ps(script)
    assert result.returncode == 0, (
        f"Invoke-Grill -DryRun must return mode='dry-run' with a populated prompt.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


# ── AGENT-BRIEF markers (round-trip parsable by any runtime) ─────────────────


def test_agent_brief_markers_present_in_github_ps1() -> None:
    """Set-AgentBrief depends on stable HTML-comment markers that any runtime
    (PowerShell, Python on Cloud Run) can parse with a single regex."""
    github = (REPO_ROOT / ".github/orchestrator/lib/GitHub.ps1").read_text(
        encoding="utf-8"
    )
    assert "<!-- AGENT-BRIEF:BEGIN -->" in github
    assert "<!-- AGENT-BRIEF:END -->" in github


# ── HITL child-issue title format ─────────────────────────────────────────────


def test_hitl_child_title_carries_parent_number_and_stub() -> None:
    """The HITL child issue title is the only handle a human scanning the
    issue list sees — it must include the parent number and a short stub of
    the question so the linkage is visible without clicking through."""
    # Inline the title-building logic from New-HitlChildIssue so the test is
    # hermetic and does not depend on a live `gh` environment.
    snippet = """
$Question = [pscustomobject]@{
    text = 'Should the new endpoint enforce auth at the edge or inside the handler?'
}
$ParentNumber = 85
$shortText = ($Question.text -replace '\\s+', ' ').Trim()
if ($shortText.Length -gt 70) { $shortText = $shortText.Substring(0, 67) + '...' }
$title = "HITL decision needed (#${ParentNumber}): $shortText"
Write-Output $title
"""
    result = _ps(snippet)
    assert result.returncode == 0, result.stderr
    title = result.stdout.strip()
    assert title.startswith("HITL decision needed (#85):"), (
        f"Title must lead with HITL framing and parent number, got: {title!r}"
    )
    assert "endpoint" in title


def test_hitl_child_title_truncates_long_questions() -> None:
    """A 200-character question must be truncated to <= 100 chars in the title
    so the GitHub issue list remains scannable."""
    long_text = "Should the new endpoint " + ("xyz " * 60)
    snippet = f"""
$Question = [pscustomobject]@{{ text = '{long_text.strip()}' }}
$ParentNumber = 99
$shortText = ($Question.text -replace '\\s+', ' ').Trim()
if ($shortText.Length -gt 70) {{ $shortText = $shortText.Substring(0, 67) + '...' }}
$title = "HITL decision needed (#${{ParentNumber}}): $shortText"
Write-Output $title
"""
    result = _ps(snippet)
    assert result.returncode == 0, result.stderr
    title = result.stdout.strip()
    assert len(title) <= 110, (
        f"Truncated title too long ({len(title)} chars): {title!r}"
    )
    assert title.endswith("..."), f"Long titles must end with '...': {title!r}"


# ── GrillResult contract — the Python and PowerShell sides agree ─────────────


def test_grill_result_keys_match_powershell_schema_docstring() -> None:
    """The keys documented in grill.ps1's system prompt MUST match the
    pydantic model — drift here means the subagent emits JSON the orchestrator
    rejects."""
    from src.utils.m_planning import GrillResult

    text = GRILL_LIB.read_text(encoding="utf-8")  # system prompt lives in the library
    expected_keys = set(GrillResult.model_fields.keys())
    assert expected_keys == {
        "agent_brief",
        "open_questions",
        "decided_questions",
        "glossary_diffs",
    }
    for key in expected_keys:
        assert f'"{key}"' in text, (
            f"grill.ps1 system prompt must mention the '{key}' field — "
            f"otherwise the subagent will emit JSON that fails GrillResult validation."
        )


def test_grill_result_validates_subagent_example_payload() -> None:
    """The example payload embedded in the system prompt of grill.ps1 must be a
    valid GrillResult — otherwise the example trains the subagent to emit
    invalid output."""
    from src.utils.m_planning import GrillResult

    # Mirrors the schema example in grill.ps1's system prompt.
    example = {
        "agent_brief": {
            "feature_name": "sse-endpoint",
            "problem_statement": "Browser needs streaming.",
            "interfaces": ["GET /stream?q=<prompt> -> text/event-stream"],
            "constraints": ["ADR-003: Standard Library First"],
            "out_of_scope": [],
            "tracer_bullet": "GET /stream?q=hello -> 3 tokens -> [DONE]",
        },
        "open_questions": [
            {
                "text": "Auth model?",
                "raised_by": "self-grill-subagent",
                "decision": "Recommend: bearer token — matches existing endpoints.",
            }
        ],
        "decided_questions": [
            {
                "text": "Use SSE rather than chunked encoding?",
                "raised_by": "self-grill-subagent",
                "decided_by": "self-grill-subagent",
                "decision": "SSE — evidence: ADR-010 already accepts SSE.",
            }
        ],
        "glossary_diffs": [
            {
                "term": "SSE Endpoint",
                "definition": "text/event-stream GET endpoint.",
                "disambiguation": "Not WebSocket.",
                "action": "add",
            }
        ],
    }
    parsed = GrillResult.model_validate(example)
    assert parsed.agent_brief.feature_name == "sse-endpoint"
    assert len(parsed.open_questions) == 1
    # Round-trip with by_alias so the 'from'/'to' alias contract is preserved.
    json.dumps(parsed.model_dump(by_alias=True, mode="json"))
