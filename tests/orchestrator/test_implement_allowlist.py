"""WritablePaths as a merge classifier (#285) — lib/Config.ps1, stages/Ship.ps1.

The allowlist no longer bars the agent from writing. It decides whether a PR can
merge on its own: every changed path must be inside `WritablePaths` **and**
outside `GovernancePaths`. Anything else is committed as a proposal and ship
holds the PR at `human:approval` for the owner to merge or reject.

These tests read the real `$OrchestratorConfig` through the module rather than
restating the patterns. The previous version of this file pasted its own copy of
`WritablePaths` into an inline snippet, so it kept passing no matter what the
real list said — the duplication class behind #252, #266 and #275.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
MODULE = Path(__file__).parents[2] / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run(body: str) -> dict:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        f"{body}\n"
        "}\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _classify(paths: list[str]) -> dict:
    """Run the real merge rule over `paths`, via a PR-diff fake."""
    emit = "; ".join(f"'{p}'" for p in paths)
    return _run(
        f"""
function script:gh {{ $global:LASTEXITCODE = 0; {emit} }}
$proposed   = @(Get-ProposedFiles   -PRNumber 1)
$governance = @(Get-GovernanceFiles -PRNumber 1)
[pscustomobject]@{{
    proposed   = @($proposed)
    governance = @($governance)
    automerges = ($proposed.Count -eq 0 -and $governance.Count -eq 0)
}} | ConvertTo-Json -Compress
"""
    )


# ── What merges on its own ────────────────────────────────────────────────────


def test_application_code_and_tests_merge_without_a_human() -> None:
    out = _classify(["src/foo.py", "tests/test_foo.py", "pyproject.toml", "uv.lock"])
    assert out["proposed"] == []
    assert out["governance"] == []
    assert out["automerges"] is True


def test_a_path_outside_the_allowlist_is_a_proposal() -> None:
    out = _classify(["src/foo.py", ".github/workflows/x.yml"])
    assert out["proposed"] == [".github/workflows/x.yml"]
    assert out["automerges"] is False


def test_writable_but_governed_still_needs_a_human() -> None:
    """CONTEXT.md, SECURITY.md and .agents/skills/ are in both lists: the agent may
    change them and have the change auto-formatted and reviewed, but never merged
    on its own. Being writable is not permission to merge."""
    out = _classify(["CONTEXT.md", ".agents/skills/plan/SKILL.md", "docs/adr/ADR-1.md"])
    assert out["proposed"] == []
    assert sorted(out["governance"]) == [
        ".agents/skills/plan/SKILL.md",
        "CONTEXT.md",
        "docs/adr/ADR-1.md",
    ]
    assert out["automerges"] is False


@pytest.mark.parametrize(
    "path",
    [
        ".github/orchestrator/lib/Config.ps1",
        ".github/workflows/afk.yml",
        ".github/CODEOWNERS",
        ".github/tasks/sync.ps1",
        "Taskfile.yml",
        "copier.yml",
        "Dockerfile",
        ".devcontainer/devcontainer.json",
        "AGENTS.md",
        ".pre-commit-config.yaml",
    ],
)
def test_nothing_outside_the_allowlist_merges_itself(path: str) -> None:
    out = _classify([path])
    assert out["automerges"] is False, f"{path} must never auto-merge"


# ── The classifier itself ─────────────────────────────────────────────────────


def test_unwritable_paths_reads_the_real_allowlist() -> None:
    """Get-UnwritablePaths is what the plan stage uses to warn early. It and
    Get-ProposedFiles must agree, since they answer the same question at two
    different moments."""
    out = _run(
        r"""
$paths = @('src/a.py', 'tests/b.py', '.github/workflows/c.yml', 'Taskfile.yml', 'docs/d.md')
[pscustomobject]@{ unwritable = @(Get-UnwritablePaths -Paths $paths) } | ConvertTo-Json -Compress
"""
    )
    assert out["unwritable"] == [".github/workflows/c.yml", "Taskfile.yml"]


def test_an_empty_allowlist_makes_everything_a_proposal() -> None:
    """Fail-safe: losing the allowlist must mean "everything needs approval", never
    "anything merges unreviewed"."""
    out = _run(
        r"""
function script:gh { $global:LASTEXITCODE = 0; 'src/foo.py'; 'tests/test_foo.py' }
$OrchestratorConfig.WritablePaths = @()
[pscustomobject]@{ proposed = @(Get-ProposedFiles -PRNumber 1) } | ConvertTo-Json -Compress
"""
    )
    assert out["proposed"] == ["src/foo.py", "tests/test_foo.py"]


def test_a_boundary_change_is_flagged_distinctly_in_the_hold() -> None:
    """A PR that widens the allowlist, edits CODEOWNERS or changes a workflow is
    altering the rules the next PR is judged by. It must not read as one bullet
    among twenty in a long file list."""
    # Each file is one line, and .NET regex `.` does not cross newlines — so these
    # patterns only match when the flag is on that file's own line.
    out = _run(
        r"""
$files = @('.github/orchestrator/lib/Config.ps1', '.github/workflows/afk.yml',
           '.github/CODEOWNERS', '.github/tasks/sync.ps1', 'Taskfile.yml')
$text = Format-HeldFiles -Files $files -Diffstat @{ 'Taskfile.yml' = '+4 -0' }
[pscustomobject]@{
    config     = [bool]($text -match 'Config\.ps1.*own boundary')
    workflow   = [bool]($text -match 'afk\.yml.*own boundary')
    codeowners = [bool]($text -match 'CODEOWNERS.*own boundary')
    taskscript = [bool]($text -match 'sync\.ps1.*own boundary')
    taskfile   = [bool]($text -match 'Taskfile\.yml.*own boundary')
    diffstat   = [bool]($text -match '\+4 -0')
} | ConvertTo-Json -Compress
"""
    )
    assert out["config"] is True
    assert out["workflow"] is True
    assert out["codeowners"] is True
    # Outside the allowlist, but these do not redefine what the next PR may do.
    assert out["taskscript"] is False
    assert out["taskfile"] is False
    assert out["diffstat"] is True
