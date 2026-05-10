"""Smoke tests: verify copier generates a working project for each project_type."""

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
    assert "mcr.microsoft.com/devcontainers/python:3.12" in devcontainer_content
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
