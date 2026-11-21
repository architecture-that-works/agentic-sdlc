"""Tests for .github/checks/check-references.ps1.

The check asserts that everything a workflow, the Taskfile or an agent document
points at exists: a script path, a repo-relative path, an orchestrator function.
These tests pin the two properties that make it useful rather than noisy: it
catches a stale reference of each kind, and it does not fire on prose, on the
template placeholders these documents legitimately contain, or on worked examples.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / ".github" / "checks" / "check-references.ps1"
PWSH = shutil.which("pwsh") or "pwsh"

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _run(root: Path) -> subprocess.CompletedProcess[str]:
    """Invoke the copy inside ``root`` — the script derives the repo root from its
    own location, so running the real one against a fixture would scan this repo."""
    return subprocess.run(
        [PWSH, "-NoProfile", "-File", str(root / ".github" / "checks" / SCRIPT.name)],
        cwd=str(root),
        capture_output=True,
        text=True,
        check=False,
    )


def _scaffold(root: Path, agents_md: str = "# Agents\n") -> None:
    """Minimal tree the check walks: a workflow, the Taskfile, AGENTS.md,
    CONTEXT.md, the tests README, a skill and one orchestrator function."""
    (root / ".github" / "checks").mkdir(parents=True)
    (root / ".github" / "workflows").mkdir(parents=True)
    (root / ".github" / "orchestrator" / "lib").mkdir(parents=True)
    (root / ".github" / "tasks").mkdir(parents=True)
    (root / "docs" / "adr").mkdir(parents=True)
    (root / ".agents" / "skills" / "demo").mkdir(parents=True)
    (root / "tests").mkdir()
    (root / "src").mkdir()

    shutil.copy(SCRIPT, root / ".github" / "checks" / SCRIPT.name)
    (root / ".github" / "orchestrator" / "lib" / "Fake.ps1").write_text(
        "function Get-FakeContext { }\n", encoding="utf-8"
    )
    (root / ".github" / "tasks" / "demo.ps1").write_text("exit 0\n", encoding="utf-8")
    (root / ".github" / "workflows" / "ci.yml").write_text(
        "jobs:\n  demo:\n    steps:\n      - run: pwsh .github/tasks/demo.ps1\n",
        encoding="utf-8",
    )
    (root / "Taskfile.yml").write_text(
        "tasks:\n  demo:\n    cmds:\n      - pwsh .github/tasks/demo.ps1\n",
        encoding="utf-8",
    )
    (root / "AGENTS.md").write_text(agents_md, encoding="utf-8")
    (root / "CONTEXT.md").write_text("# CONTEXT\n", encoding="utf-8")
    (root / "tests" / "README.md").write_text("# Tests\n", encoding="utf-8")
    (root / ".agents" / "skills" / "demo" / "SKILL.md").write_text(
        "# Demo\n", encoding="utf-8"
    )


def test_passes_when_every_reference_resolves(tmp_path: Path) -> None:
    _scaffold(
        tmp_path,
        "See `src/` and [the skill](.agents/skills/demo/SKILL.md); "
        "`Get-FakeContext` hydrates the run context.\n",
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr


# ── script paths in workflows and the Taskfile ───────────────────────────────


def test_fails_on_a_missing_script_in_a_workflow(tmp_path: Path) -> None:
    _scaffold(tmp_path)
    (tmp_path / ".github" / "workflows" / "ci.yml").write_text(
        "jobs:\n  demo:\n    steps:\n      - run: pwsh .github/tasks/gone.ps1\n",
        encoding="utf-8",
    )
    result = _run(tmp_path)
    assert result.returncode == 1
    assert ".github/workflows/ci.yml: script does not exist" in result.stdout
    assert ".github/tasks/gone.ps1" in result.stdout


def test_fails_on_a_missing_script_in_the_taskfile(tmp_path: Path) -> None:
    _scaffold(tmp_path)
    (tmp_path / "Taskfile.yml").write_text(
        "tasks:\n  demo:\n    cmds:\n      - uv run python src/tools/gone.py\n",
        encoding="utf-8",
    )
    result = _run(tmp_path)
    assert result.returncode == 1
    assert "Taskfile.yml: script does not exist" in result.stdout
    assert "src/tools/gone.py" in result.stdout


def test_a_glob_in_a_workflow_is_not_a_script_path(tmp_path: Path) -> None:
    """The checks job runs `check-*.ps1` by pattern; that is not a stale path."""
    _scaffold(tmp_path)
    (tmp_path / ".github" / "workflows" / "ci.yml").write_text(
        "jobs:\n  checks:\n    steps:\n"
        "      - run: Get-ChildItem .github/checks -Filter 'check-*.ps1'\n",
        encoding="utf-8",
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout


# ── paths cited in agent documents ───────────────────────────────────────────


def test_fails_on_a_stale_backticked_path(tmp_path: Path) -> None:
    _scaffold(tmp_path, "The library lives in `.github/scripts/kanban/`.\n")
    result = _run(tmp_path)
    assert result.returncode == 1
    assert "AGENTS.md: path does not exist" in result.stdout
    assert ".github/scripts/kanban/" in result.stdout


def test_fails_on_a_stale_markdown_link_target(tmp_path: Path) -> None:
    _scaffold(tmp_path, "[reference](.agents/skills/gone/REFERENCE.md)\n")
    result = _run(tmp_path)
    assert result.returncode == 1
    assert ".agents/skills/gone/REFERENCE.md" in result.stdout


@pytest.mark.parametrize(
    "citation",
    [
        "`Planner/Generator/Evaluator`",  # prose containing slashes
        "`text/event-stream`",  # a media type, not a path
        "`CI/CD`",
        "`src/<domain>/`",  # angle-bracket placeholder
        "`src/utils/m_*.py`",  # glob placeholder
        "`docs/adr/ADR-NNN-kebab-title.md`",  # naming template
        "`https://example.com/docs/thing.md`",  # URL
    ],
)
def test_does_not_fire_on_non_paths(tmp_path: Path, citation: str) -> None:
    """A noisy check gets disabled, so the shape rule must reject these outright."""
    _scaffold(tmp_path, f"Prose mentioning {citation} inline.\n")
    result = _run(tmp_path)
    assert result.returncode == 0, (
        f"{citation} must not be treated as a repo path\n{result.stdout}"
    )


# ── orchestrator function names cited in agent documents ─────────────────────


def test_fails_on_an_unknown_function_name(tmp_path: Path) -> None:
    _scaffold(tmp_path, "Uses `Get-BogusFunction` to hydrate the run context.\n")
    result = _run(tmp_path)
    assert result.returncode == 1
    assert "AGENTS.md: function does not exist" in result.stdout
    assert "Get-BogusFunction" in result.stdout


def test_non_verb_noun_token_is_ignored(tmp_path: Path) -> None:
    """Spans with spaces, parameter flags and lowercase tokens fail the shape filter."""
    _scaffold(
        tmp_path,
        "Conducted via `Invoke-Orchestration -From refine`; media type `text/event-stream`.\n",
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout


def test_context_md_is_not_scanned_for_functions(tmp_path: Path) -> None:
    """CONTEXT.md cites core cmdlets such as Import-Module, which are not orchestrator functions."""
    _scaffold(tmp_path)
    (tmp_path / "CONTEXT.md").write_text(
        "Each task runnable calls `Import-Module`.\n", encoding="utf-8"
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout


# ── scope ────────────────────────────────────────────────────────────────────


def test_examples_md_is_not_scanned(tmp_path: Path) -> None:
    """Worked examples describe a fictional feature; their references are illustrative."""
    _scaffold(tmp_path)
    (tmp_path / ".agents" / "skills" / "demo" / "EXAMPLES.md").write_text(
        "The agent creates `src/payments/__init__.py` and calls `Invoke-FictionalStage`.\n",
        encoding="utf-8",
    )
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout


def test_every_failure_says_what_to_change(tmp_path: Path) -> None:
    _scaffold(tmp_path, "See `.github/gone/` and `Get-BogusFunction`.\n")
    result = _run(tmp_path)
    assert result.returncode == 1
    failures = [line for line in result.stdout.splitlines() if "does not exist" in line]
    assert len(failures) == 2
    assert all(" — fix " in line or " — name " in line for line in failures), failures


def test_the_real_repository_holds() -> None:
    """The repository's own workflows and agent documents point only at live targets."""
    result = _run(REPO_ROOT)
    assert result.returncode == 0, (
        "Stale references in workflows or agent documents:\n" + result.stdout
    )
