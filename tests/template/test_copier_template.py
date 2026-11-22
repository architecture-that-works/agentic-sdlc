"""Smoke tests: verify copier generates a working project."""

import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

import copier

TEMPLATE_ROOT = Path(__file__).parent.parent.parent
# The test folders that test the template itself and stay home (copier.yml _exclude).
TEMPLATE_TEST_FOLDERS = (
    "checks",
    "decisions",
    "evals",
    "fakes",
    "journeys",
    "repository",
    "template",
)
# Imports the orchestrator module in a generated project and finds its conductor.
_IMPORT_MODULE = (
    "$env:GITHUB_REPOSITORY = 'octocat/sandbox'; "
    "$env:GITHUB_DEFAULT_BRANCH = 'main'; "
    "Import-Module ./.github/orchestrator/Orchestrator.psd1 -DisableNameChecking; "
    "if (-not (Get-Command Invoke-Orchestration -Module Orchestrator)) { exit 1 }"
)


def test_generated_project_passes_tests(tmp_path: Path) -> None:
    # vcs_ref="HEAD" ensures staged-but-uncommitted template changes are included —
    # without it, Copier defaults to the latest git tag (v0.1.1, long stale), so this
    # smoke test was silently exercising a months-old snapshot instead of the current
    # template (surfaced by the devcontainer image assertion below going stale).
    copier.run_copy(
        src_path=str(TEMPLATE_ROOT),
        dst_path=str(tmp_path),
        data={
            "project_name": "smoke-app",
            "description": "Template smoke test",
        },
        defaults=True,
        unsafe=True,
        overwrite=True,
        vcs_ref="HEAD",
    )

    pyproject = (tmp_path / "pyproject.toml").read_text()
    assert 'name = "smoke-app"' in pyproject, (
        f"pyproject.toml has wrong project name:\n{pyproject}"
    )

    devcontainer_json = tmp_path / ".devcontainer" / "devcontainer.json"
    assert devcontainer_json.exists(), (
        "Generated project missing .devcontainer/devcontainer.json"
    )
    devcontainer_content = devcontainer_json.read_text()
    assert "{{" not in devcontainer_content, (
        ".devcontainer/devcontainer.json must not contain Jinja2 syntax"
    )
    assert (
        "mcr.microsoft.com/devcontainers/python:3.14-bookworm" in devcontainer_content
    )
    assert "ghcr.io/devcontainers/features/github-cli:1" in devcontainer_content
    assert "ghcr.io/devcontainers/features/powershell:1" in devcontainer_content
    assert "ghcr.io/devcontainers/features/docker-in-docker:2" in devcontainer_content
    assert "claude-code" in devcontainer_content, (
        "devcontainer must install the claude CLI"
    )
    assert "GitHub.Copilot" not in devcontainer_content, (
        "devcontainer must not include Copilot extension"
    )

    docker_compose = tmp_path / ".devcontainer" / "docker-compose.devcontainer.yml"
    assert docker_compose.exists(), (
        "Generated project missing .devcontainer/docker-compose.devcontainer.yml"
    )
    compose_content = docker_compose.read_text()
    assert "{{" not in compose_content, (
        "docker-compose.devcontainer.yml must not contain Jinja2 syntax"
    )
    assert "postgres" in compose_content.lower(), (
        "Compose stub must include a PostgreSQL example"
    )
    assert "ollama" in compose_content.lower(), (
        "Compose stub must include an Ollama example"
    )

    dockerfile = tmp_path / "Dockerfile"
    assert dockerfile.exists(), "Generated project missing Dockerfile"
    dockerfile_content = dockerfile.read_text()
    assert "pip install" not in dockerfile_content, (
        "Dockerfile must not contain 'pip install'"
    )
    assert "{{" not in dockerfile_content, "Dockerfile must not contain Jinja2 syntax"

    dockerignore = tmp_path / ".dockerignore"
    assert dockerignore.exists(), "Generated project missing .dockerignore"
    dockerignore_content = dockerignore.read_text()
    assert ".venv/" in dockerignore_content, ".dockerignore must exclude .venv/"
    assert ".env" in dockerignore_content, ".dockerignore must exclude .env"

    assert (tmp_path / "src" / "main.py").exists(), (
        "Generated project missing src/main.py"
    )

    assert (tmp_path / ".env.example").exists(), (
        "Generated project missing .env.example"
    )

    for rel in (
        ".github/ISSUE_TEMPLATE/issue.md",
        ".github/ISSUE_TEMPLATE/config.yml",
        ".github/PULL_REQUEST_TEMPLATE.md",
        "CONTRIBUTING.md",
    ):
        shipped = tmp_path / rel
        assert shipped.exists(), f"Generated project missing {rel}"
        text = shipped.read_text()
        assert "{{" not in text and "{%" not in text, (
            f"{rel} must not contain Jinja2 syntax"
        )

    agents_md_content = (tmp_path / "AGENTS.md").read_text()
    assert "{{" not in agents_md_content, "AGENTS.md must not contain Jinja2 syntax"

    # Template-only directories must not travel.
    for stale in (".template", "template", "adr-staging"):
        assert not (tmp_path / stale).exists(), (
            f"Generated project must not contain {stale!r} directory"
        )

    # docs/adr/ contains exactly ADR-000, the blank form.
    adr_entries = sorted(p.name for p in (tmp_path / "docs" / "adr").iterdir())
    assert adr_entries == ["ADR-000-template-architecture-decision.md"], (
        f"docs/adr/ must contain exactly the blank ADR-000; got {adr_entries}"
    )

    # Copier answers file exists and records the template commit.
    answers = tmp_path / ".copier-answers.yml"
    assert answers.exists(), "Generated project missing .copier-answers.yml"
    answers_text = answers.read_text()
    assert "_commit" in answers_text, (
        ".copier-answers.yml must record _commit so `copier update` can run"
    )

    # ISSUES.md ships without any pending blocks.
    issues_md = (tmp_path / "ISSUES.md").read_text()
    assert "<!-- ISSUES -->" in issues_md, (
        "Generated ISSUES.md must contain the ISSUES sentinel"
    )
    _, _, below = issues_md.partition("<!-- ISSUES -->")
    for line in below.splitlines():
        assert not line.startswith("ISSUE:"), (
            f"Generated ISSUES.md must have no ISSUE: lines below the sentinel; found {line!r}"
        )

    # .out-of-scope.md ships without any rejection entries.
    oos_md = (tmp_path / ".out-of-scope.md").read_text()
    for line in oos_md.splitlines():
        assert not line.startswith("## "), (
            f"Generated .out-of-scope.md must have no '## ' entries; found {line!r}"
        )

    # A project carries the tests of its own code only (#408): tests/app/, and none of
    # the folders that test the template's orchestrator, workflows, checks and skills.
    assert (tmp_path / "tests" / "app").is_dir(), "Generated project missing tests/app/"
    for kept_home in TEMPLATE_TEST_FOLDERS:
        assert not (tmp_path / "tests" / kept_home).exists(), (
            f"Generated project must not contain tests/{kept_home}/"
        )

    # The test command, the module and the checks all need pwsh. A missing pwsh fails
    # the test rather than skipping it: a skipped gate reports green.
    pwsh = shutil.which("pwsh")
    assert pwsh is not None, "pwsh not found: the generated project's checks need it"

    # The one test command runs pytest alone there, and says Pester was not run.
    result = subprocess.run(
        [pwsh, "-NoProfile", "-File", ".github/tasks/test.ps1"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, (
        "The test command failed in the generated project:\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )
    assert "Pester  not run" in result.stdout, (
        f"The test command must say Pester was not run:\n{result.stdout}"
    )

    # The orchestrator travels, and its module loads.
    module = subprocess.run(
        [
            pwsh,
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            _IMPORT_MODULE,
        ],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert module.returncode == 0, (
        "The orchestrator module does not load in the generated project:\n"
        f"stdout:\n{module.stdout}\n"
        f"stderr:\n{module.stderr}"
    )

    # check-module-map.ps1 and check-token-scope.ps1 interrogate git — initialise
    # and commit so they see the generated project as a repo. Every check-*.ps1 runs,
    # the same rule as the checks job in checks.yml.
    for argv in (
        ["git", "init", "-q", "-b", "main"],
        ["git", "config", "user.email", "ci@example.com"],
        ["git", "config", "user.name", "ci"],
        ["git", "add", "-A"],
        ["git", "commit", "-qm", "initial"],
    ):
        subprocess.run(argv, cwd=tmp_path, check=True, capture_output=True, text=True)
    for check in sorted((tmp_path / ".github" / "checks").glob("check-*.ps1")):
        check_result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(check)],
            cwd=tmp_path,
            capture_output=True,
            text=True,
            check=False,
        )
        assert check_result.returncode == 0, (
            f"{check.name} failed inside generated project:\n"
            f"stdout:\n{check_result.stdout}\n"
            f"stderr:\n{check_result.stderr}"
        )


def test_pre_commit_config_inherited_via_copier(tmp_path: Path) -> None:
    # vcs_ref="HEAD" ensures staged-but-uncommitted template changes are included
    # in the generated project, matching how copier behaves between tagged releases.
    copier.run_copy(
        src_path=str(TEMPLATE_ROOT),
        dst_path=str(tmp_path),
        data={
            "project_name": "smoke-precommit",
            "description": "Pre-commit smoke test",
        },
        defaults=True,
        unsafe=True,
        overwrite=True,
        vcs_ref="HEAD",
    )

    pre_commit_config = tmp_path / ".pre-commit-config.yaml"
    assert pre_commit_config.exists(), (
        "Generated project missing .pre-commit-config.yaml — "
        "pre-commit config must travel via copier (issue #120)"
    )

    content = pre_commit_config.read_text()
    assert "uv run ruff check" in content, (
        ".pre-commit-config.yaml must invoke 'uv run ruff check' to mirror CI lint job"
    )
    assert "uv run ruff format --check" in content, (
        ".pre-commit-config.yaml must invoke 'uv run ruff format --check' to mirror CI lint job"
    )
    assert "language: system" in content, (
        ".pre-commit-config.yaml must use language: system so uv run resolves "
        "the project ruff without a separate pre-commit-managed environment"
    )


def test_licence_names_the_project_and_codeowners_stays_home(tmp_path: Path) -> None:
    # #393: a project gets the template's MIT text in its own name, and none of the
    # template's code owners — task setup writes a project's .github/CODEOWNERS.
    copier.run_copy(
        src_path=str(TEMPLATE_ROOT),
        dst_path=str(tmp_path),
        data={"project_name": "acme-widget"},
        defaults=True,
        unsafe=True,
        overwrite=True,
        vcs_ref="HEAD",
    )

    licence = tmp_path / "LICENSE"
    assert licence.exists(), "Generated project missing LICENSE"
    text = licence.read_text()
    template_text = (TEMPLATE_ROOT / "LICENSE").read_text()
    assert text.startswith("MIT License\n"), f"LICENSE is not MIT:\n{text}"

    copyright_lines = [ln for ln in text.splitlines() if ln.startswith("Copyright")]
    assert len(copyright_lines) == 1, f"expected one copyright line:\n{text}"
    # The year comes from Copier's built-in strftime filter (jinja2-ansible-filters,
    # a Copier dependency), so generation needs no extra package.
    match = re.fullmatch(
        r"Copyright \(c\) (\d{4}) acme-widget contributors", copyright_lines[0]
    )
    assert match, f"copyright line must be year + project only: {copyright_lines[0]!r}"
    assert abs(int(match.group(1)) - datetime.now().year) <= 1, (
        f"copyright year is not the generation year: {copyright_lines[0]!r}"
    )

    # Everything but the copyright line is the template's MIT text, word for word.
    def _body(licence_text: str) -> list[str]:
        return [
            ln for ln in licence_text.splitlines() if not ln.startswith("Copyright")
        ]

    assert _body(text) == _body(template_text), "LICENSE must keep the MIT text"
    for template_line in template_text.splitlines():
        if template_line.startswith("Copyright"):
            assert template_line not in text, (
                "LICENSE must not carry the template's own copyright line"
            )
    assert "{{" not in text, "LICENSE must not contain Jinja2 syntax"
    assert not (tmp_path / "LICENSE.jinja2").exists()

    assert not (tmp_path / ".github" / "CODEOWNERS").exists(), (
        "The template's own .github/CODEOWNERS must not be copied into a project"
    )


def test_skills_travel_via_copier(tmp_path: Path) -> None:
    copier.run_copy(
        src_path=str(TEMPLATE_ROOT),
        dst_path=str(tmp_path),
        data={
            "project_name": "smoke-skills",
            "description": "Skills travel smoke test",
        },
        defaults=True,
        unsafe=True,
        overwrite=True,
        vcs_ref="HEAD",
    )

    agents_md = (tmp_path / "AGENTS.md").read_text()

    skills_section_match = re.search(
        r"^## Skills\b.*?(?=^## |\Z)", agents_md, re.MULTILINE | re.DOTALL
    )
    assert skills_section_match is not None, (
        "Generated AGENTS.md has no ## Skills section"
    )

    skill_names = re.findall(
        r"^\|\s*`([^`]+)`\s*\|", skills_section_match.group(), re.MULTILINE
    )
    assert skill_names, "No skill names found in ## Skills table of generated AGENTS.md"

    skills_dir = tmp_path / ".agents" / "skills"
    for name in skill_names:
        skill_md = skills_dir / name / "SKILL.md"
        assert skill_md.exists(), (
            f"Skill '{name}' listed in AGENTS.md §Skills but "
            f".agents/skills/{name}/SKILL.md not found in generated project"
        )

    unlisted = sorted(
        p.name for p in skills_dir.iterdir() if p.is_dir() and p.name not in skill_names
    )
    assert not unlisted, (
        f"Skill folders not listed in AGENTS.md §Skills of generated project: {unlisted}"
    )
