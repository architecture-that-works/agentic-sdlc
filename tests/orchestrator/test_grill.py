"""Tests for the self-grill subagent harness (issue #85).

Two surfaces are exercised:

1. ``.github/orchestrator/lib/Grill.ps1`` — the dot-sourceable function
   library (Invoke-Grill); must expose the function with no side effects and no
   scope leak. ``grill.ps1`` is the thin standalone CLI wrapper around it,
   invocable in ``-DryRun`` mode without contacting Claude (see ADR-013).
2. ``.github/orchestrator/lib/GitHub.ps1`` § ``Set-AgentBrief`` markers — the
   AGENT-BRIEF section is bounded by HTML-comment markers that must remain
   identifiable from outside PowerShell (Python parsers, future Cloud Run
   service, etc.).

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
    REPO_ROOT / ".github" / "orchestrator" / "lib" / "Grill.ps1"
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
    """Dot-sourcing the LIBRARY (Grill.ps1) must expose ``Invoke-Grill`` without
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
        f"Dot-sourcing Grill.ps1 must expose Invoke-Grill without clobbering "
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


def test_grill_never_decides_a_choice_the_issue_reserves_for_the_owner() -> None:
    """A build/defer/drop choice the issue reserves for the owner is never the
    grill's to make: the exception to Rule 1 keeps such choices as open questions,
    with the recommendation."""
    prompt = (
        Path(__file__).parents[2] / ".github" / "orchestrator" / "lib" / "Grill.ps1"
    ).read_text(encoding="utf-8")
    assert "reserves a choice for the owner" in prompt
    assert "Put it in\n           `open_questions[]` with your recommendation" in prompt


# ── The subagent's run, read from the CLI's JSON envelope ────────────────────
# Live on #212 the subagent's reply was not JSON; refine carried on with a stub and
# granted agent:backlog without asking the owner anything. Every way the run can
# go wrong now throws with the reason, so the refine attempt fails instead.

_PAYLOAD = {
    "agent_brief": {
        "feature_name": "x",
        "problem_statement": "p",
        "interfaces": [],
        "constraints": [],
        "out_of_scope": [],
        "tracer_bullet": "t",
    },
    "open_questions": [],
    "decided_questions": [],
    "glossary_diffs": [],
}


def _grill_with_output(lines: list[str]) -> subprocess.CompletedProcess[str]:
    fake = "; ".join(f"'{ln.replace(chr(39), chr(39) * 2)}'" for ln in lines)
    return _ps(
        f". '{GRILL_LIB.as_posix()}'\n"
        f"function claude {{ $input | Out-Null; $global:LASTEXITCODE = 0; {fake} }}\n"
        "try { $r = Invoke-Grill -Title 'T' -Body 'B'; 'OK:' + $r.agent_brief.feature_name }\n"
        "catch { 'ERR:' + $_.Exception.Message }"
    )


def _envelope(subtype: str, result: str, turns: int = 3) -> str:
    return json.dumps(
        {
            "type": "result",
            "subtype": subtype,
            "is_error": subtype != "success",
            "num_turns": turns,
            "result": result,
        }
    )


def test_grill_reads_the_answer_even_with_prose_around_it() -> None:
    reply = "Here is the result:\n" + json.dumps(_PAYLOAD) + "\nDone."
    out = _grill_with_output(["trust warning on stderr", _envelope("success", reply)])
    assert out.stdout.strip() == "OK:x", out.stdout + out.stderr


def test_grill_that_runs_out_of_turns_fails_with_the_reason() -> None:
    out = _grill_with_output([_envelope("error_max_turns", "", turns=40)])
    assert out.stdout.startswith("ERR:"), out.stdout + out.stderr
    assert "error_max_turns" in out.stdout and "40 turn(s)" in out.stdout


def _tool_use(*names: str) -> str:
    content = [
        {"type": "tool_use", "id": f"t{i}", "name": n, "input": {}}
        for i, n in enumerate(names)
    ]
    content.insert(0, {"type": "text", "text": "Reading the codebase first."})
    return json.dumps({"type": "assistant", "message": {"content": content}})


def test_grill_trace_lists_the_tools_it_called_in_order() -> None:
    """The eval's Tool Correctness metric needs the grill's tool calls (#155); the
    stream-json events carry them, the result envelope still carries the answer."""
    lines = [
        json.dumps({"type": "system", "subtype": "init"}),
        _tool_use("Read", "Glob"),
        _tool_use("Grep"),
        _envelope("success", json.dumps(_PAYLOAD)),
    ]
    fake = "; ".join(f"'{ln.replace(chr(39), chr(39) * 2)}'" for ln in lines)
    out = _ps(
        f". '{GRILL_LIB.as_posix()}'\n"
        "function claude { $input | Out-Null; $script:Args = $args; $global:LASTEXITCODE = 0; "
        f"{fake} }}\n"
        "$r = Invoke-Grill -Title 'T' -Body 'B' -Trace\n"
        "[pscustomobject]@{ tools = $r.tools_called; brief = $r.result.agent_brief.feature_name;"
        " args = ($script:Args -join ' ') } | ConvertTo-Json -Compress"
    )
    data = json.loads(out.stdout.strip().splitlines()[-1])
    assert data["tools"] == ["Read", "Glob", "Grep"], out.stderr
    assert data["brief"] == "x"
    assert "stream-json" in data["args"] and "--verbose" in data["args"]


def test_grill_without_trace_returns_the_grill_result_unchanged() -> None:
    """Refine consumes the plain GrillResult — the trace must stay opt-in."""
    out = _grill_with_output(
        [_tool_use("Read"), _envelope("success", json.dumps(_PAYLOAD))]
    )
    assert out.stdout.strip() == "OK:x", out.stdout + out.stderr


def test_grill_without_a_result_or_valid_answer_fails() -> None:
    no_result = _grill_with_output(["Error: something broke"])
    assert (
        "gave no result" in no_result.stdout and "something broke" in no_result.stdout
    )
    prose = _grill_with_output([_envelope("success", "I could not decide.")])
    assert (
        "not a valid GrillResult" in prose.stdout and "could not decide" in prose.stdout
    )


def test_grill_fetches_the_issue_even_with_gh_stderr_noise() -> None:
    """#270: the issue-fetch call merged gh's stderr into the same string as its
    JSON stdout via 2>&1, so any incidental notice/warning on stderr broke the
    strict ConvertFrom-Json with a cryptic error instead of fetching cleanly."""
    out = _ps(
        f". '{GRILL_LIB.as_posix()}'\n"
        "function gh {\n"
        "  Write-Error -Message 'a notice gh prints to stderr' -ErrorAction Continue\n"
        "  $global:LASTEXITCODE = 0\n"
        '  \'{"title":"T","body":"B"}\'\n'
        "}\n"
        f"function claude {{ $input | Out-Null; $global:LASTEXITCODE = 0; "
        f"'{_envelope('success', json.dumps(_PAYLOAD))}' }}\n"
        "try { $r = Invoke-Grill -Issue 42; 'OK:' + $r.agent_brief.feature_name }\n"
        "catch { 'ERR:' + $_.Exception.Message }"
    )
    assert out.stdout.strip() == "OK:x", out.stdout + out.stderr


def test_grill_issue_fetch_failure_names_the_issue_and_stderr() -> None:
    """A genuine gh failure (non-zero exit) must raise a clear, actionable error —
    not an opaque JSON-conversion exception."""
    out = _ps(
        f". '{GRILL_LIB.as_posix()}'\n"
        "function gh {\n"
        "  Write-Error -Message 'HTTP 404: Not Found' -ErrorAction Continue\n"
        "  $global:LASTEXITCODE = 1\n"
        "}\n"
        "try { Invoke-Grill -Issue 42 }\n"
        "catch { 'ERR:' + $_.Exception.Message }"
    )
    assert "ERR:" in out.stdout
    assert "#42" in out.stdout
    assert "404" in out.stdout
