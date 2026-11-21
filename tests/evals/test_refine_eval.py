"""Eval: the refine skill's self-grill — the pipeline-side example.

Each stored case is an under-specified issue. The grill probe (the skill's own script, so
the eval exercises the real skill prompt) grills it with Claude and returns its result
with the tools it called. The check reads both: every tool the case expects was called
(Rule 1, codebase first); every open question has a recommendation and two alternatives
(Rule 2); and the agent brief names no source file or line (Rule 4).
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest
from eval_goldens import load_goldens

REPO_ROOT = Path(__file__).resolve().parents[2]
GRILL = REPO_ROOT / ".agents" / "skills" / "refine" / "scripts" / "grill.ps1"
GOLDENS = load_goldens("refine")

# A file name ending in .py or .ps1, with its `:<line>` reference if any (`Util.ps1:113`).
# A `:<digits>` counts only after such a name: a timestamp (`2026-11-21T10:15`) or a
# port (`localhost:8080`) in a brief is not a line reference.
SOURCE_REFERENCE = re.compile(r"[\w*-]+\.(?:py|ps1)(?::L?\d+)?\b")


def grill(title: str, body: str) -> dict:
    """Run the probe with -Trace: { result: GrillResult, tools_called: [...] }."""
    out = subprocess.run(
        [
            "pwsh",
            "-NoProfile",
            "-File",
            str(GRILL),
            "-Title",
            title,
            "-Body",
            body,
            "-Trace",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=REPO_ROOT,
        # grill.ps1 imports the orchestrator module, which needs a repository slug and
        # a default branch; a run without an 'origin' remote has neither.
        env={
            **os.environ,
            "GITHUB_REPOSITORY": os.environ.get("GITHUB_REPOSITORY")
            or "octocat/sandbox",
            "GITHUB_DEFAULT_BRANCH": os.environ.get("GITHUB_DEFAULT_BRANCH") or "main",
        },
        timeout=900,
        check=False,
    )
    assert out.returncode == 0, out.stderr or out.stdout
    return json.loads(out.stdout[out.stdout.index("{") :])


def _strings(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [s for v in value.values() for s in _strings(v)]
    if isinstance(value, list):
        return [s for v in value for s in _strings(v)]
    return []


def refine_violations(run: dict, expected_tools: list[str]) -> list[str]:
    """The rules the grill run breaks; empty when it passes."""
    result = run["result"]
    violations = [
        f"expected tool not called: {tool}"
        for tool in expected_tools
        if tool not in run["tools_called"]
    ]
    for question in result.get("open_questions") or []:
        alternatives = [a for a in question.get("alternatives") or [] if a.strip()]
        if not (question.get("decision") or "").strip() or len(alternatives) != 2:
            violations.append(
                f"open question lacks a recommendation and two alternatives: "
                f"{question.get('text')!r}"
            )
    violations += [
        f"agent brief names a source file or line: {match!r}"
        for text in _strings(result.get("agent_brief"))
        for match in SOURCE_REFERENCE.findall(text)
    ]
    return violations


@pytest.mark.eval
@pytest.mark.parametrize("case", GOLDENS, ids=[g["id"] for g in GOLDENS])
def test_refine_grill(case) -> None:
    run = grill(case["title"], case["input"])
    violations = refine_violations(run, case["expected_tools"])
    assert violations == [], f"{violations}\n{json.dumps(run, indent=2)}"


def test_refine_violations() -> None:
    brief = {
        "feature_name": "rate-limit",
        "problem_statement": "The server is overloaded by bursts of requests.",
        "interfaces": [
            "A request to localhost:8080 over the limit gets 429 with Retry-After."
        ],
        "timestamp": "2026-11-21T10:15:00Z",
        "constraints": ["Standard library first (CONTEXT.md); ADR-009."],
    }
    question = {
        "text": "Limit per client or globally?",
        "decision": "Per client IP — because one client causes the bursts",
        "alternatives": ["Global — simpler", "Per token — needs auth"],
    }
    good = {
        "result": {"agent_brief": brief, "open_questions": [question]},
        "tools_called": ["Glob", "Read"],
    }
    assert refine_violations(good, ["Read"]) == []

    bad = {
        "result": {
            "agent_brief": {**brief, "tracer_bullet": "Wrap do_GET in src/main.py:12"},
            "open_questions": [{**question, "alternatives": ["Global"]}],
        },
        "tools_called": ["Glob"],
    }
    assert len(refine_violations(bad, ["Read"])) == 3
