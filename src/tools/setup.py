"""Populate CONTEXT.md sentinel tokens from .copier-answers.yml."""

import subprocess
import sys
from pathlib import Path

import yaml

_SENTINELS: dict[str, str] = {
    "__PROJECT_NAME__": "project_name",
    "__PROJECT_DESCRIPTION__": "description",
    "__PROJECT_TYPE__": "project_type",
}

_CONTEXT_FILE = Path("CONTEXT.md")
_ANSWERS_FILE = Path(".copier-answers.yml")


def load_answers(answers_path: Path) -> dict:
    return yaml.safe_load(answers_path.read_text(encoding="utf-8"))


def replace_sentinels(content: str, answers: dict) -> str:
    for sentinel, key in _SENTINELS.items():
        value = answers.get(key, "")
        content = content.replace(sentinel, str(value))
    return content


def set_github_variable(project_type: str) -> None:
    subprocess.run(
        ["gh", "variable", "set", "PROJECT_TYPE", "--body", project_type],
        check=True,
    )


def main() -> None:
    if not _ANSWERS_FILE.exists():
        print(
            f"Error: {_ANSWERS_FILE} not found. Run copier copy first.", file=sys.stderr
        )
        sys.exit(1)

    answers = load_answers(_ANSWERS_FILE)
    content = _CONTEXT_FILE.read_text(encoding="utf-8")
    updated = replace_sentinels(content, answers)
    _CONTEXT_FILE.write_text(updated, encoding="utf-8")

    project_type = answers.get("project_type", "")
    set_github_variable(project_type)


if __name__ == "__main__":
    main()
