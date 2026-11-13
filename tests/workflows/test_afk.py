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
    """Text of one top-level job, up to the next job header or its section divider.

    Every job in afk.yml is introduced by a `  # ── Name ──` divider. Stopping at
    one matters: without it a job absorbed the *next* job's leading comment, so
    describing one job's rules in prose made assertions about the job above it
    fail — which is what adding the reconcile job's comment block did to
    test_any_feature_pr_close_reconciles_the_issue (#278).
    """
    text = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        rf"^  {name}:\n(.*?)(?=^  [\w-]+:\n|^  # ──|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
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
    """A comment from someone with write access is now handled by the central comment
    router job, not the refine job. The router calls Invoke-Orchestration -From comment
    which dispatches to refine, retry, revise, or ack based on the live pipeline label."""
    text = WORKFLOW.read_text(encoding="utf-8")
    assert re.search(r"issue_comment:\s*\n\s*types: \[created\]", text)
    comment = _job("comment")
    for guard in (
        "github.event_name == 'issue_comment'",
        "!github.event.issue.pull_request",
        '["OWNER","MEMBER","COLLABORATOR"]',
        "github.event.comment.author_association",
        "!startsWith(github.event.comment.body, '🤖')",
        "!startsWith(github.event.comment.body, '·')",
    ):
        assert guard in comment, guard
    assert "Invoke-Orchestration -From comment" in comment, (
        "comment job must call the central router"
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
    """The refine job no longer handles issue_comment events at all — the central
    comment router job is the sole issue_comment consumer. A comment on a
    human:approval issue triggers the router, which dispatches to 'revise' via
    Invoke-Orchestration -From comment, never to refine directly."""
    refine = _job("refine")
    assert "github.event_name == 'issue_comment'" not in refine, (
        "refine job if: must not condition on issue_comment — the comment job handles all comments"
    )


def test_comment_job_routes_owner_comment():
    """The comment job is the sole issue_comment consumer and calls the central router."""
    comment = _job("comment")
    assert "github.event_name == 'issue_comment'" in comment
    assert "Invoke-Orchestration -From comment" in comment
    assert '["OWNER","MEMBER","COLLABORATOR"]' in comment
    assert "github.event.comment.author_association" in comment
    assert "!startsWith(github.event.comment.body, '🤖')" in comment
    assert "!startsWith(github.event.comment.body, '·')" in comment
    assert "KANBAN_ISSUE" in comment


def test_refine_job_has_no_issue_comment_trigger():
    """After moving all comment routing to the comment job, the refine job must
    not trigger on issue_comment — that path is gone (#297)."""
    refine = _job("refine")
    assert "github.event_name == 'issue_comment'" not in refine, (
        "refine job if: must not use issue_comment — the comment job is the sole consumer"
    )


def test_pipeline_comment_skipped_in_comment_job():
    """The 🤖/· prefix filter prevents the pipeline from reacting to its own
    comments and must be present in the comment job's if: condition."""
    comment = _job("comment")
    assert "startsWith(github.event.comment.body, '🤖')" in comment
    assert "startsWith(github.event.comment.body, '·')" in comment
