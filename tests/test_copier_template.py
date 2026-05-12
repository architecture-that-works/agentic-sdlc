"""Smoke tests: verify copier generates a working project for each project_type."""

import re
import subprocess
from pathlib import Path

import copier
import pytest

TEMPLATE_ROOT = Path(__file__).parent.parent


@pytest.mark.parametrize("project_type", ["application", "agent", "ml"])
def test_generated_project_passes_tests(project_type: str, tmp_path: Path) -> None:
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
        "mcr.microsoft.com/devcontainers/python:1-3.12-bookworm" in devcontainer_content
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

    result = subprocess.run(
        ["uv", "run", "pytest", "--tb=short", "-q"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"pytest failed for project_type={project_type!r}:\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
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
