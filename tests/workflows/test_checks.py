"""Guards for .github/workflows/checks.yml — the one rule for .github/checks/.

The `checks` job runs every `check-*.ps1` in the folder by pattern, so a new
check is a new file and no check is named in the workflow. Static text checks
(no YAML library, no pwsh) so they run on every CI runner and in every
generated project.
"""

import re
from pathlib import Path

ROOT = Path(__file__).parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "checks.yml"
CHECKS = ROOT / ".github" / "checks"
PROTECT = ROOT / ".github" / "tasks" / "protect.ps1"


def _code() -> str:
    """The workflow without comment lines."""
    text = WORKFLOW.read_text(encoding="utf-8")
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def _job_names() -> list[str]:
    jobs = _code().split("\njobs:\n", 1)[1]
    return re.findall(r"^  ([A-Za-z0-9_-]+):\s*$", jobs, re.MULTILINE)


def _job(name: str) -> str:
    """Text of one top-level job, up to the next job header."""
    jobs = _code().split("\njobs:\n", 1)[1]
    match = re.search(
        rf"^  {re.escape(name)}:\s*\n(.*?)(?=^  [A-Za-z0-9_-]+:\s*$|\Z)",
        jobs,
        re.MULTILINE | re.DOTALL,
    )
    assert match, f"no job named {name!r} in checks.yml"
    return match.group(1)


def test_no_job_is_named_guards() -> None:
    assert "guards" not in _job_names()


def test_checks_job_runs_the_folder_by_pattern() -> None:
    job = _job("checks")
    assert ".github/checks" in job
    assert "'check-*.ps1'" in job
    assert job.count("- name:") + job.count("- run:") + job.count("- uses:") == 2, (
        "the checks job is one checkout and one step that runs the folder"
    )


def test_no_check_is_named_in_the_workflow() -> None:
    """A hand-written list drifts from the folder; the pattern cannot."""
    code = _code()
    named = [c.name for c in CHECKS.glob("*.ps1") if c.name in code]
    assert not named, f"checks.yml names {named}; run them by pattern instead"


def test_checks_job_has_full_history_on_pull_requests() -> None:
    """check-module-map compares the pull request with its base branch."""
    job = _job("checks")
    assert "github.event_name == 'pull_request'" in job
    assert "fetch-depth: 0" in job


def test_folder_holds_only_checks() -> None:
    """Anything in the folder that is not a check-*.ps1 would never run."""
    stray = [
        p.name for p in CHECKS.iterdir() if not re.fullmatch(r"check-.+\.ps1", p.name)
    ]
    assert not stray, f".github/checks/ holds files CI never runs: {stray}"


def test_every_check_says_what_it_guards() -> None:
    """Line 1 is #Requires; the SYNOPSIS opens with the one sentence on what it guards."""
    for check in sorted(CHECKS.glob("check-*.ps1")):
        lines = check.read_text(encoding="utf-8").splitlines()
        assert lines[0] == "#Requires -Version 7.0", check.name
        synopsis = lines.index(".SYNOPSIS")
        assert lines[synopsis + 1].strip().startswith("Guards "), check.name


def test_required_checks_are_jobs_of_the_workflow() -> None:
    """A required status no job reports blocks every merge on main."""
    text = PROTECT.read_text(encoding="utf-8")
    match = re.search(r"^\$RequiredChecks\s*=\s*@\(([^)]*)\)", text, re.MULTILINE)
    assert match, "no $RequiredChecks list in protect.ps1"
    required = re.findall(r'"([^"]+)"', match.group(1))
    assert "checks" in required
    missing = [name for name in required if name not in _job_names()]
    assert not missing, f"protect.ps1 requires checks no job reports: {missing}"
