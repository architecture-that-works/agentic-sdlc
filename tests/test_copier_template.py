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
