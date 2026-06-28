"""Regression guards for the kanban orchestrator's GraphQL budget.

The orchestrator is GraphQL-bound: `gh issue/pr/project/repo` calls hit GitHub's
GraphQL API (5000 pts/hr), which throttles separately from REST (also 5000/hr,
near-idle). Projects v2 board moves are GraphQL-only and irreducible, but
default-branch resolution and issue-label reads/writes are not. This module
asserts those levers stay off GraphQL so a future edit can't silently
reintroduce a `gh repo view` or `gh issue edit --add-label` on the hot path.

Background: memory `project_graphql_budget` (ADR-012). Static-source checks (no
pwsh/gh needed) so they run on every CI runner.
"""

import re
from pathlib import Path

KANBAN = Path(__file__).parents[2] / ".github" / "scripts" / "kanban"
CONFIG = (
    KANBAN / "Config.ps1"
)  # repo slug + default branch resolution (the fallback site)
GITHUB = KANBAN / "GitHub.ps1"  # labels, agent state, board
WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "orchestrator.yml"

# Library scripts that run inside a drain and must never resolve the default
# branch via GraphQL. Config.ps1 is the one place a guarded last-resort fallback
# is allowed (see test_config_gh_repo_view_only_guarded_fallback).
STAGE_SCRIPTS = [p for p in KANBAN.glob("*.ps1") if p.name != "Config.ps1"]


def _code_lines(path: Path) -> list[str]:
    """Lines of a .ps1 file with full-line `#` comments removed."""
    return [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    ]


def _code(path: Path) -> str:
    return "\n".join(_code_lines(path))


# ---------------------------------------------------------------------------
# Default branch — resolved via git/env, not `gh repo view` (GraphQL)
# ---------------------------------------------------------------------------


def test_no_gh_repo_view_in_stage_scripts() -> None:
    assert STAGE_SCRIPTS, "no kanban library scripts found — wrong path?"
    offenders = {
        p.name: [ln for ln in _code_lines(p) if "gh repo view" in ln]
        for p in STAGE_SCRIPTS
    }
    offenders = {name: lines for name, lines in offenders.items() if lines}
    assert not offenders, (
        "`gh repo view` is GraphQL — library scripts must use $KanbanDefaultBranch "
        f"/ $ctx.DefaultBranch:\n{offenders}"
    )


def test_config_gh_repo_view_only_guarded_fallback() -> None:
    """Config.ps1 may keep `gh repo view` only as a silent last-resort fallback."""
    hits = [ln for ln in _code_lines(CONFIG) if "gh repo view" in ln]
    # Two allowed fallbacks: repo slug + default branch.
    assert len(hits) <= 2, f"unexpected `gh repo view` usage in Config.ps1:\n{hits}"
    for ln in hits:
        assert "2>$null" in ln, (
            f"`gh repo view` in Config.ps1 must be the guarded fallback form: {ln!r}"
        )


def test_no_gh_repo_view_in_orchestrator_workflow() -> None:
    """The workflow's inline pwsh must read the default branch from the job env
    (GITHUB_DEFAULT_BRANCH), never via GraphQL `gh repo view`."""
    hits = [ln for ln in _code_lines(WORKFLOW) if "gh repo view" in ln]
    assert not hits, (
        f"orchestrator.yml must use $GITHUB_DEFAULT_BRANCH, not `gh repo view`:\n{hits}"
    )


def test_orchestrator_workflow_sets_default_branch_env() -> None:
    code = _code(WORKFLOW)
    assert "GITHUB_DEFAULT_BRANCH" in code, (
        "orchestrator.yml should export GITHUB_DEFAULT_BRANCH from the event payload"
    )


def test_default_branch_cached_in_config() -> None:
    code = _code(CONFIG)
    assert "$KanbanDefaultBranch =" in code, "expected a cached $KanbanDefaultBranch"
    assert "GITHUB_DEFAULT_BRANCH" in code, (
        "expected the GITHUB_DEFAULT_BRANCH env var as the zero-cost source"
    )


def test_scripts_reference_cached_default_branch() -> None:
    """The scripts that previously called `gh repo view` now read the cached
    default branch — the `$KanbanDefaultBranch` constant (phases) or the run
    context (`$ctx.DefaultBranch`, Orchestrator.ps1; see ADR-013)."""
    for name in ("Implement.ps1", "Merge.ps1", "Orchestrator.ps1"):
        code = _code(KANBAN / name)
        assert "DefaultBranch" in code, (
            f"{name} should resolve the default branch from the cache "
            f"($KanbanDefaultBranch or $ctx.DefaultBranch), not `gh repo view`"
        )


# ---------------------------------------------------------------------------
# Hot label reads/writes — routed to REST, not GraphQL `gh issue view/edit`
# ---------------------------------------------------------------------------


def test_set_issuelabel_writes_via_rest() -> None:
    code = _code(GITHUB)
    # The GraphQL label-write flags must be gone from the shared helpers.
    assert "--add-label" not in code and "--remove-label" not in code, (
        "label add/remove must go through `gh api .../labels` (REST), not "
        "`gh issue edit --add-label/--remove-label` (GraphQL)"
    )
    # ...and the REST endpoints must be present.
    assert re.search(r"gh api .*issues/\$Number/labels", code), (
        "Set-IssueLabel should POST/DELETE repos/.../issues/{n}/labels via REST"
    )


def test_agent_label_read_via_rest() -> None:
    code = _code(GITHUB)
    # No GraphQL label read remains.
    assert not re.search(r"gh issue view .*--json labels", code), (
        "the agent:* label read must use `gh api .../labels` (REST), not "
        "`gh issue view --json labels` (GraphQL)"
    )
    assert re.search(r"gh api .*issues/\$IssueNumber/labels", code), (
        "Set-AgentState should read the current label via REST repos/.../labels"
    )
