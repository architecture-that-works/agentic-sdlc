"""Map staged src/**/*.py files to their test counterparts and run them.

Usage: staged_tests.py <staged_file> [<staged_file> ...]
Skips files outside src/ or with no matching tests/<sub>/test_<name>.py.
Exits 0 immediately if no mapped test files exist (nothing to run).
"""

import os
import sys
from pathlib import Path


def _repo_root() -> Path:
    here = Path(__file__).resolve().parent
    for candidate in (here.parent, here):
        if (candidate / "pyproject.toml").exists():
            return candidate
    return here.parent


ROOT = _repo_root()


def _staged_to_test(staged: str) -> Path | None:
    """Return tests/<sub>/test_<name>.py for src/<sub>/<name>.py, or None."""
    path = Path(staged)
    if path.suffix != ".py":
        return None
    abs_path = path if path.is_absolute() else (ROOT / path).resolve()
    try:
        rel = abs_path.relative_to(ROOT / "src")
    except ValueError:
        return None
    return ROOT / "tests" / rel.parent / ("test_" + rel.name)


def main(argv: list[str]) -> int:
    if not argv:
        return 0

    test_paths: list[str] = []
    for arg in argv:
        test_path = _staged_to_test(arg)
        if test_path is not None and test_path.exists():
            test_paths.append(str(test_path))

    if not test_paths:
        return 0

    os.execvp("uv", ["uv", "run", "pytest", "--no-cov", *test_paths])
    return 0  # unreachable after execvp


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
