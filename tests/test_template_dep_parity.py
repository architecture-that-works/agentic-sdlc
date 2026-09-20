"""Guard that third-party dev deps imported in tests/ appear in both pyproject.toml files.

Catches the class of bug where a package is added to the template repo's own dev
dependencies for tests, but not to pyproject.toml.jinja2, breaking every generated
project's test run (e.g. hypothesis was missing from .jinja2 after issue #154).
"""

import ast
import re
import sys
import tomllib
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
TESTS_DIR = REPO_ROOT / "tests"
PYPROJECT = REPO_ROOT / "pyproject.toml"
PYPROJECT_JINJA = REPO_ROOT / "pyproject.toml.jinja2"

# tests/ is copied verbatim into generated projects, which render pyproject.toml from
# the template and so carry no pyproject.toml.jinja2. Parity is a property of the
# template repo, not of a project produced from it — skip there rather than raising
# FileNotFoundError and failing every generated project's suite. Absence of the
# template file is the signal that we are running inside a generated project.
pytestmark = pytest.mark.skipif(
    not PYPROJECT_JINJA.exists(),
    reason="template-only guard: generated projects have no pyproject.toml.jinja2",
)

# Maps import name -> distribution name where they differ (e.g. {"PIL": "Pillow"})
_MODULE_TO_DIST: dict[str, str] = {}

_FIRST_PARTY = {"src", "tests"}


def _collect_test_imports() -> set[str]:
    stdlib = sys.stdlib_module_names
    modules: set[str] = set()
    for py_file in TESTS_DIR.rglob("*.py"):
        try:
            tree = ast.parse(py_file.read_text(encoding="utf-8"))
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    top = alias.name.split(".")[0]
                    if top not in stdlib and top not in _FIRST_PARTY:
                        modules.add(top)
            elif isinstance(node, ast.ImportFrom):
                if node.level > 0 or not node.module:
                    continue
                top = node.module.split(".")[0]
                if top not in stdlib and top not in _FIRST_PARTY:
                    modules.add(top)
    return modules


def _parse_dev_deps(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    # Strip Jinja2 block tags; expression tags inside TOML strings are already valid TOML
    text = re.sub(r"\{%-?.*?-?%\}", "", text, flags=re.DOTALL)
    data = tomllib.loads(text)
    raw = data.get("dependency-groups", {}).get("dev", [])
    result: set[str] = set()
    for dep in raw:
        if isinstance(dep, str):
            name = re.split(r"[><=!;~\s\[]", dep)[0].strip()
            result.add(name.lower().replace("-", "_"))
    return result


def test_test_imports_declared_in_both_pyprojects() -> None:
    third_party = _collect_test_imports()
    pyproject_deps = _parse_dev_deps(PYPROJECT)
    jinja_deps = _parse_dev_deps(PYPROJECT_JINJA)

    # Only enforce parity for packages explicitly managed as dev deps in either file.
    # Transitive deps (e.g. pydantic via pydantic-settings) and runtime deps are
    # available in both environments implicitly and are intentionally excluded.
    declared = pyproject_deps | jinja_deps

    failures: list[str] = []
    for module in sorted(third_party):
        dist = _MODULE_TO_DIST.get(module, module).lower().replace("-", "_")
        if dist not in declared:
            continue
        if dist not in pyproject_deps:
            failures.append(
                f"  '{dist}' (imported as '{module}') is missing from pyproject.toml"
            )
        if dist not in jinja_deps:
            failures.append(
                f"  '{dist}' (imported as '{module}') is missing from pyproject.toml.jinja2"
            )

    if failures:
        pytest.fail(
            "Third-party test imports not declared in all pyproject.toml files:\n"
            + "\n".join(failures)
        )
