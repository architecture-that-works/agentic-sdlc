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


def test_agent_backlog_label_starts_implementation():
    """agent:backlog is the go signal: adding the label runs implement → review → ship."""
    implement = _job("implement")
    assert "github.event.action == 'labeled'" in implement
    assert "github.event.label.name == 'agent:backlog'" in implement


def test_every_new_issue_is_refined():
    refine = _job("refine")
    assert "github.event.action == 'opened'" in refine
    assert "!contains(github.event.issue.labels.*.name, 'human:decision')" not in refine


def test_owner_comment_re_refines_or_retries():
    """A comment from someone with write access drives refine (or a retry when the
    issue is agent:failed); the pipeline's own 🤖/· comments and outsiders never do."""
    text = WORKFLOW.read_text(encoding="utf-8")
    assert re.search(r"issue_comment:\s*\n\s*types: \[created\]", text)
    refine = _job("refine")
    for guard in (
        "github.event_name == 'issue_comment'",
        "!github.event.issue.pull_request",
        '["OWNER","MEMBER","COLLABORATOR"]',
        "github.event.comment.author_association",
        "!startsWith(github.event.comment.body, '🤖')",
        "!startsWith(github.event.comment.body, '·')",
        "contains(github.event.issue.labels.*.name, 'agent:failed')",
    ):
        assert guard in refine, guard
    assert "tasks/retry.ps1" in refine, (
        "a comment on agent:failed resumes the failed stage"
    )


def test_no_decision_child_issues_or_close_trigger():
    text = WORKFLOW.read_text(encoding="utf-8")
    types = re.search(r"issues:\s*\n\s*types: \[([^\]]*)\]", text)
    assert types, "issues trigger not found"
    assert "closed" not in types.group(1)
    assert "options: [refine, implement, ship]" in text


def test_ship_runs_only_on_the_owners_dispatch():
    """Ship once ran on the agent:reviewing label, which review sets before it
    approves — a cancelled or crashed run could then merge an unreviewed PR."""
    ship = _job("ship")
    assert (
        "if: github.event_name == 'workflow_dispatch' && inputs.stage == 'ship'" in ship
    )
    assert "agent:reviewing" not in ship


def test_any_feature_pr_close_reconciles_the_issue():
    """Any feature-branch PR's closed event reconciles its issue — merged outside
    the pipeline, merged by Invoke-Ship, or a held PR the owner merged — so a direct
    `gh pr merge` still lands the issue on agent:shipped (#252). The job skips only
    an issue Test-IssueShipped already reports as shipped, not merely an unheld or
    a previously-failed one (#266/#275)."""
    text = WORKFLOW.read_text(encoding="utf-8")
    assert re.search(r"pull_request:\s*\n\s*types: \[closed\]", text)
    job = _job("pr-closed")
    assert "github.event.pull_request.head.repo.full_name == github.repository" in job
    assert "startsWith(github.event.pull_request.head.ref, 'feature/')" in job
    assert "Test-IssueShipped" in job
    assert "agent:failed" not in job
    assert "human:approval" not in job
    assert "Complete-HeldPR" in job


def test_a_comment_on_a_held_issue_does_not_trigger_refine():
    """#225: a held issue carries only human:approval (no agent:* label), so the
    'no agent: label' comment trigger alone would send it back to refine."""
    refine = _job("refine")
    assert "!contains(github.event.issue.labels.*.name, 'human:approval')" in refine
