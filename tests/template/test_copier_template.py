"""Smoke tests: verify copier generates a working project for each project_type."""

import re
import shutil
import subprocess
from pathlib import Path

import copier
import pytest

TEMPLATE_ROOT = Path(__file__).parent.parent.parent


def test_generated_project_passes_tests(tmp_path: Path) -> None:
    # vcs_ref="HEAD" ensures staged-but-uncommitted template changes are included —
    # without it, Copier defaults to the latest git tag (v0.1.1, long stale), so this
    # smoke test was silently exercising a months-old snapshot instead of the current
    # template (surfaced by the devcontainer image assertion below going stale).
    project_type = "application"
    copier.run_copy(
        src_path=str(TEMPLATE_ROOT),
        dst_path=str(tmp_path),
        data={
            "project_name": f"smoke-{project_type}",
            "description": "Template smoke test",
            "project_type": project_type,
        },
        defaults=True,
        unsafe=True,
        overwrite=True,
        vcs_ref="HEAD",
    )

    pyproject = (tmp_path / "pyproject.toml").read_text()
    assert f'name = "smoke-{project_type}"' in pyproject, (
        f"pyproject.toml has wrong project name for project_type={project_type!r}:\n{pyproject}"
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
        f"Generated project missing src/main.py for project_type={project_type!r}"
    )

    assert (tmp_path / ".env.example").exists(), (
        f"Generated project missing .env.example for project_type={project_type!r}"
    )

    agents_md_content = (tmp_path / "AGENTS.md").read_text()
    assert "{{" not in agents_md_content, (
        f"AGENTS.md must not contain Jinja2 syntax for project_type={project_type!r}"
    )

    # Template-only directories must not travel.
    for stale in (".template", "template", "adr-staging", "tests/template"):
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

    result = subprocess.run(
        ["uv", "run", "pytest", "--tb=short", "-q"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, (
        f"pytest failed for project_type={project_type!r}:\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )

    pwsh = shutil.which("pwsh")
    if pwsh is None:
        pytest.skip("pwsh not available — cannot run generated-project checks")
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
            "project_type": "application",
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


def test_skills_travel_via_copier(tmp_path: Path) -> None:
    copier.run_copy(
        src_path=str(TEMPLATE_ROOT),
        dst_path=str(tmp_path),
        data={
            "project_name": "smoke-skills",
            "description": "Skills travel smoke test",
            "project_type": "application",
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

    for name in skill_names:
        skill_md = tmp_path / ".agents" / "skills" / name / "SKILL.md"
        assert skill_md.exists(), (
            f"Skill '{name}' listed in AGENTS.md §Skills but "
            f".agents/skills/{name}/SKILL.md not found in generated project"
        )
