"""Guards for .github/workflows/afk.yml — the unattended pipeline.

Static checks (no gh/pwsh needed) so they run on every CI runner.
"""

import re
from pathlib import Path

WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "afk.yml"


def test_engine_is_pinned_to_an_installed_cli():
    """The cloud runners install only the Claude CLI, so the engine must be pinned.

    Reading `vars.KANBAN_ENGINE` let the repository variable (set to `gemini` for
    local HITL runs) select an engine whose CLI is absent on the runner, and every
    AFK run died in Assert-EngineReady before the refine stage started.
    """
    text = WORKFLOW.read_text(encoding="utf-8")
    code = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    assert "vars.KANBAN_ENGINE" not in code
    engines = re.findall(r"^\s*KANBAN_ENGINE:\s*(\S+)\s*$", code, re.MULTILINE)
    assert engines == ["claude"]
    assert "npm install -g @anthropic-ai/claude-code" in code


def _job(name: str) -> str:
    """Text of one top-level job, up to the next job header."""
    text = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        rf"^  {name}:\n(.*?)(?=^  [\w-]+:\n|\Z)", text, re.MULTILINE | re.DOTALL
    )
    assert match, f"job {name!r} not found"
    return match.group(1)


def test_all_is_the_default_dispatch_and_drains_after_refining():
    """One trigger: stage=all refines everything un-aligned, then drains the backlog."""
    text = WORKFLOW.read_text(encoding="utf-8")
    assert re.search(r"default: all\s+options: \[all, refine, implement, ship\]", text)
    refine = _job("refine")
    assert "inputs.stage == 'all'" in refine
    drain = refine[refine.index("name: Drain") :]
    assert "stage=implement" in drain, "stage=all must dispatch the implement drain"


def test_closing_a_decision_issue_re_refines_its_parent():
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "types: [opened, labeled, closed]" in text
    refine = _job("refine")
    assert "github.event.action == 'closed'" in refine
    assert "contains(github.event.issue.labels.*.name, 'human:decision')" in refine
    assert "Parent" in refine, "the parent is read from the decision issue body"
