"""Guards for .github/workflows/afk.yml — the unattended pipeline.

Static checks (no gh/pwsh needed) so they run on every CI runner.
"""

import re
from pathlib import Path

WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "afk.yml"


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


def test_a_strangers_issue_never_starts_refine():
    """On a public repo anyone can open an issue, and refine runs with the owner's
    tokens — so the opened trigger checks the author like the comment job does (#312)."""
    refine = _job("refine")
    assert '["OWNER","MEMBER","COLLABORATOR"]' in refine
    assert "github.event.issue.author_association" in refine


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


def test_the_pr_closed_job_stores_no_credentials_and_runs_no_model():
    """Reconciling a closed PR only sets labels and posts comments through gh, so
    the job never pushes (#349): every checkout is credential-free, and nothing that
    existed only for the old post-merge CONTEXT.md update — a second credentialed
    checkout, the Claude CLI, a git identity, the Claude token — is left."""
    job = _job("pr-closed")
    checkouts = job.count("actions/checkout@")
    assert checkouts >= 1
    assert job.count("persist-credentials: false") == checkouts
    assert "token: ${{ secrets.GH_TOKEN }}" not in job
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in job
    assert "npm install" not in job
    assert "git config" not in job


def test_every_merge_checks_the_held_prs_for_a_conflict():
    """After every merged feature-branch PR, whoever merged it, the conflict-rounds
    job starts a round for each held PR that now conflicts (#374). It is a job of
    its own, not a step behind pr-closed's shipped-issue gate, so the pipeline's own
    merge — whose issue is already agent:shipped — runs it too."""
    job = _job("conflict-rounds")
    pr_closed = _job("pr-closed")
    for guard in (
        "github.event_name == 'pull_request'",
        "github.event.pull_request.merged == true",
        "github.event.pull_request.head.repo.full_name == github.repository",
        "startsWith(github.event.pull_request.head.ref, 'feature/')",
    ):
        assert guard in job
    assert "always()" in job and "needs: pr-closed" in job
    assert "Start-ConflictRounds -MergedPR" in job
    assert "steps.reconcile" not in job
    # pr-closed is unchanged: its gate still guards only Complete-HeldPR.
    assert "Start-ConflictRounds" not in pr_closed
    assert "github.event.pull_request.merged == true" not in pr_closed


def test_conflict_checks_run_one_at_a_time_and_store_no_credentials():
    """Two merges close together must not both see an issue at human:approval and
    start two rounds, so every run shares one group, whatever the PR. The probe only
    reads fetched refs, so git stores no credentials (#349)."""
    job = _job("conflict-rounds")
    group = re.search(r"concurrency:\s*\n\s*group: (\S+)", job)
    assert group and group.group(1) == "conflict-rounds"
    assert "cancel-in-progress: false" in job
    assert "fetch-depth: 0" in job
    checkouts = job.count("actions/checkout@")
    assert checkouts == 1
    assert job.count("persist-credentials: false") == checkouts
    assert "token: ${{ secrets.GH_TOKEN }}" not in job
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in job
    assert "npm install" not in job


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


def test_no_secret_in_workflow_level_env():
    """GH_TOKEN and CLAUDE_CODE_OAUTH_TOKEN must not appear in the workflow-level
    env block — they must be scoped to the individual steps that use them."""
    text = WORKFLOW.read_text(encoding="utf-8")
    # Extract lines between the top-level "env:" key and the first "jobs:" line.
    top_env_lines: list[str] = []
    in_top_env = False
    for line in text.splitlines():
        if re.match(r"^env:\s*$", line):
            in_top_env = True
            continue
        if in_top_env:
            if re.match(r"^[a-zA-Z]", line):
                break
            top_env_lines.append(line)

    top_env = "\n".join(top_env_lines)
    assert "GH_TOKEN" not in top_env, (
        "GH_TOKEN must not appear in the workflow-level env block"
    )
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in top_env, (
        "CLAUDE_CODE_OAUTH_TOKEN must not appear in the workflow-level env block"
    )


def test_installer_steps_precede_credentialed_checkouts():
    """Every uv or npm install step must appear before any actions/checkout step
    that stores credentials (i.e. one without persist-credentials: false).

    pr-closed and reconcile use a credential-free checkout, so their installs
    never run with a PAT stored in git config.
    """
    text = WORKFLOW.read_text(encoding="utf-8")

    # Split into job blocks (text between "  <job>:" headers).
    job_blocks = re.split(r"^  # ──.*$", text, flags=re.MULTILINE)

    # Match each block to its job name via its first "  <name>:" line.
    job_name_re = re.compile(r"^\s{2}([a-zA-Z][a-zA-Z0-9_-]*):\s*$", re.MULTILINE)

    for block in job_blocks:
        m = job_name_re.search(block)
        if not m:
            continue
        job_name = m.group(1)

        # Split the block into individual steps at "      - " boundaries (6 spaces).
        steps = re.split(r"(?=^      - )", block, flags=re.MULTILINE)

        credentialed_checkout_indices: list[int] = []
        installer_indices: list[int] = []

        _secret_names = (
            "GH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
        )

        for idx, step in enumerate(steps):
            is_checkout = "actions/checkout" in step
            has_no_creds = "persist-credentials: false" in step
            is_installer = bool(re.search(r"\buv\b", step)) or "npm install" in step

            if is_checkout and not has_no_creds:
                credentialed_checkout_indices.append(idx)
            if is_installer:
                installer_indices.append(idx)
                # Installer steps must not carry any known secret in their env block.
                for secret in _secret_names:
                    assert secret not in step, (
                        f"job '{job_name}': installer step (index {idx}) "
                        f"has secret '{secret}' in its env"
                    )

        for inst_idx in installer_indices:
            for co_idx in credentialed_checkout_indices:
                assert inst_idx < co_idx, (
                    f"job '{job_name}': installer step (index {inst_idx}) appears "
                    f"after credentialed checkout (index {co_idx})"
                )
