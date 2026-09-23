"""Architecture contract for the orchestrator PowerShell scripts (ADR-013).

The scripts split into roles:

* **Library** — `.github/orchestrator/` — the module: lib/, stages/ and engines/. The module's loader (`Orchestrator.psm1`) dot-sources these.
  A dot-sourced file MUST NOT declare a top-level ``param()`` block: dot-sourcing
  runs that block in the *caller's* scope, injecting the parameter defaults and
  silently clobbering the caller's variables. That is how ``grill.ps1``'s
  ``param([int]$Issue = 0)`` once zeroed the orchestrator's issue number, running
  the whole pipeline against #0.
* **Tasks** — `.github/scripts/tasks/` thin Taskfile/workflow commands. They own a
  ``param()`` and are invoked (Import-Module), never dot-sourced.

These static checks enforce that separation so the scope-leak class cannot
return. Run parameters flow via the env transport + ``Get-OrchestratorContext``.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Both trees hold PowerShell subject to the library/runnable contract: the module
# under .github/orchestrator/, and the runnable task + check scripts that invoke it.
SCRIPTS = ROOT / ".github"
MODULE = ROOT / ".github" / "orchestrator"
REFINE = ROOT / ".agents" / "skills" / "refine" / "scripts"

# `. "$PSScriptRoot\..\foo.ps1"` — capture the trailing basename being sourced.
_DOT_SOURCE_RE = re.compile(r'^\s*\.\s+"\$PSScriptRoot[^"]*?([A-Za-z0-9_]+\.ps1)"')
# A top-level param() block sits at column 0 (function params are indented).
_TOP_LEVEL_PARAM_RE = re.compile(r"^param\s*\(")


def _script_files() -> list[Path]:
    """All PowerShell under .github/ (module, tasks, checks) plus the refine
    skill's scripts, which carry a param() and must stay runnables."""
    files = list(SCRIPTS.rglob("*.ps1")) + list(SCRIPTS.rglob("*.psm1"))
    files += list(REFINE.glob("*.ps1"))
    return sorted(set(files))


def _has_top_level_param(path: Path) -> bool:
    return any(
        _TOP_LEVEL_PARAM_RE.match(line)
        for line in path.read_text(encoding="utf-8").splitlines()
    )


def _dot_sourced_basenames() -> set[str]:
    names: set[str] = set()
    for f in _script_files():
        for line in f.read_text(encoding="utf-8").splitlines():
            m = _DOT_SOURCE_RE.match(line)
            if m:
                names.add(m.group(1))
    return names


def _resolve(name: str) -> Path | None:
    """Locate a dot-sourced file by basename.

    The module is searched first, and the match must be case-exact: ADR-015 makes
    casing the library/runnable signal, so `stages/Refine.ps1` (library) and
    `tasks/refine.ps1` (runnable) differ only by case — and `rglob` is
    case-insensitive on Windows.
    """
    for base in (MODULE, SCRIPTS, REFINE):
        for p in base.rglob(name):
            if p.name == name:
                return p
    return None


def test_dot_sourced_libraries_have_no_top_level_param() -> None:
    """The core contract: nothing that is dot-sourced may carry a top-level
    param() block (it would leak into the caller's scope)."""
    sourced = _dot_sourced_basenames()
    assert sourced, "expected the Orchestrator.psm1 loader to dot-source library files"
    offenders = {}
    for name in sorted(sourced):
        path = _resolve(name)
        assert path is not None, f"dot-sourced file not found: {name}"
        if _has_top_level_param(path):
            offenders[name] = str(path)
    assert not offenders, (
        "dot-sourced libraries must not declare a top-level param() — it leaks "
        f"into the caller's scope (ADR-013):\n{offenders}"
    )


def test_grill_cli_is_not_dot_sourced() -> None:
    """The grill.ps1 CLI wrapper has a param() block, so it must never be
    dot-sourced — the module dot-sources the Grill.ps1 library instead."""
    assert "grill.ps1" not in _dot_sourced_basenames(), (
        "grill.ps1 (the param()-carrying CLI) must not be dot-sourced; "
        "dot-source Grill.ps1 (the library) instead."
    )


def test_grill_library_exists_and_has_no_param() -> None:
    """The grill library is dot-sourced by the module loader, so a top-level
    param() would execute in the caller's scope. That is how grill.ps1's
    `param([int]$Issue = 0)` once zeroed the orchestrator's issue number and ran
    the whole pipeline against issue #0 (ADR-013)."""
    lib = ROOT / ".github" / "orchestrator" / "lib" / "Grill.ps1"
    assert lib.exists(), f"missing grill library: {lib}"
    assert not _has_top_level_param(lib), (
        "Grill.ps1 is dot-sourced and must not declare a top-level param()"
    )


def test_task_scripts_are_not_dot_sourced() -> None:
    """Task entry points own a param() and are invoked, never dot-sourced."""
    sourced = _dot_sourced_basenames()
    for entry in (
        "afk.ps1",
        "hitl.ps1",
        "refine.ps1",
        "retry.ps1",
        "setup.ps1",
        "sync.ps1",
        "protect.ps1",
    ):
        assert entry not in sourced, (
            f"{entry} is a task entry point and must not be dot-sourced"
        )


_PSSCRIPTROOT_PATH = re.compile(r"\$PSScriptRoot([\\/][^\"'\s)]*)")


def test_psscriptroot_paths_resolve_inside_the_repo() -> None:
    """Every $PSScriptRoot-relative path in a runnable must resolve inside the repo.

    check-script-paths.ps1 only scans workflows and Taskfile.yml, so when the
    runnables moved from scripts/ to .github/tasks/ their `..\\..\\orchestrator`
    imports went on pointing one level too high and every local task failed on
    Import-Module, while setup.ps1 resolved its .env one level above the repo.
    """
    bad = []
    for script in sorted((ROOT / ".github").glob("*/*.ps1")):
        if script.parent.name not in ("tasks", "checks"):
            continue
        for rel in _PSSCRIPTROOT_PATH.findall(script.read_text(encoding="utf-8")):
            target = (script.parent / rel.replace("\\", "/").lstrip("/")).resolve()
            if not target.exists() or not target.is_relative_to(ROOT):
                bad.append(f"{script.relative_to(ROOT)}: $PSScriptRoot{rel} -> {target}")
    assert not bad, "unresolvable $PSScriptRoot paths:\n" + "\n".join(bad)


# ── Pipeline-flow contract (ADR-014) ─────────────────────────────────────────
# Alignment (refine → architect → plan) is the pre-backlog gate that grants
# agent:backlog. Processing (Implement → Review → Merge) is a separate, already-
# aligned flow. Artefacts live IN the issue body — there is no .planning/.

MODULE = ROOT / ".github" / "orchestrator"
STAGES = MODULE / "stages"


def _stage(name: str) -> str:
    return (STAGES / name).read_text(encoding="utf-8")


def test_alignment_conductor_exists() -> None:
    """Orchestrator.psm1 owns the Backlog gate: Invoke-Orchestration -From refine conducts
    refine → architect → plan and grants agent:backlog."""
    conductor = (MODULE / "Orchestrator.psm1").read_text(encoding="utf-8")
    assert "function Invoke-Orchestration" in conductor, (
        "Orchestrator.psm1 must define Invoke-Orchestration"
    )
    for step in ("Invoke-Refine", "Invoke-Architect", "Invoke-Plan"):
        assert step in conductor, f"Invoke-Orchestration must run {step}"
    assert "agent:backlog" in conductor, (
        "Invoke-Orchestration must grant agent:backlog when the readiness gate clears"
    )


def test_orphaned_architect_stub_removed() -> None:
    """The phase-1 Invoke-Architect stub is retired — the real Architect step is
    Invoke-Architect (Architect.ps1)."""
    assert "function Invoke-Architect " not in _stage("Refine.ps1"), (
        "the orphaned Invoke-Architect stub must be removed; use Invoke-Architect"
    )


def test_implement_does_not_run_alignment_phases() -> None:
    """The Implementing lane is Develop → PR only — alignment happened pre-backlog."""
    impl = _stage("Implement.ps1")
    assert "Invoke-Architect" not in impl, (
        "Implement.ps1 must not run architecture — it is a pre-backlog gate step"
    )
    assert "Invoke-Refine" not in impl, (
        "Implement.ps1 must not run refine — it is a pre-backlog gate step"
    )


def test_no_planning_directory_artifacts() -> None:
    """No orchestrator library script may write to a .planning/ directory — artefacts
    live in the issue body (ADR-011/ADR-014). Docstrings that *mention* the
    retirement of .planning/ are stripped first so only real code is checked."""
    offenders = {
        p.name for p in MODULE.rglob("*.ps1") if ".planning" in _code_no_comments(p)
    }
    assert not offenders, (
        f".planning/ references must be gone — write into the issue body instead: {offenders}"
    )


def test_architecture_writes_into_issue_body() -> None:
    """The Architect step writes the impact into the body via Set-IssueBodySection
    and marks readiness.architected."""
    arch = _stage("Architect.ps1")
    assert "Set-IssueBodySection" in arch, (
        "Architect.ps1 must write the impact into the issue body"
    )
    assert "BLAST_RADIUS.md" not in arch, (
        "Architect.ps1 must not emit a .planning/ BLAST_RADIUS.md file"
    )
    assert "architected" in arch, "Architect.ps1 must set readiness.architected"


_BLOCK_COMMENT_RE = re.compile(r"<#.*?#>", re.DOTALL)


def _code_no_comments(path: Path) -> str:
    """Source with PowerShell block comments (<# #>) and full-line # comments
    removed — leaves only executable code for substring contracts."""
    text = _BLOCK_COMMENT_RE.sub("", path.read_text(encoding="utf-8"))
    return "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
