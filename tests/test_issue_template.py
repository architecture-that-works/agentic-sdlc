"""The issue template, ISSUES.md and the intake skill hold the same four headings."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / ".github" / "ISSUE_TEMPLATE" / "issue.md"
CONFIG = ROOT / ".github" / "ISSUE_TEMPLATE" / "config.yml"
CONTRIBUTING = ROOT / "CONTRIBUTING.md"
EXPECTED = ["Goal", "Description", "Requirements", "Acceptance Criteria"]
HEADING = re.compile(r"^\*\*([^*]+)\*\*:", re.MULTILINE)


def _headings(text: str) -> list[str]:
    return HEADING.findall(text)


def _front_matter(text: str) -> tuple[str, str]:
    match = re.match(r"\A---\n(.*?)\n---\n(.*)\Z", text, re.DOTALL)
    assert match, "issue template must start with YAML front matter"
    return match.group(1), match.group(2)


def _section(text: str, heading: str) -> str:
    match = re.search(
        rf"^#+ {re.escape(heading)}\n(.*?)(?=^#+ |\Z)", text, re.MULTILINE | re.DOTALL
    )
    assert match, f"section {heading!r} not found"
    return match.group(1)


def _first_fence(text: str) -> str:
    match = re.search(r"```\n(.*?)```", text, re.DOTALL)
    assert match, "no fenced example found"
    return match.group(1)


def test_template_headings() -> None:
    _, body = _front_matter(TEMPLATE.read_text())
    assert _headings(body) == EXPECTED


def test_issues_md_block_format_headings() -> None:
    block = _first_fence(_section((ROOT / "ISSUES.md").read_text(), "Block Format"))
    assert _headings(block) == EXPECTED


def test_intake_draft_headings() -> None:
    text = (ROOT / ".agents" / "skills" / "intake" / "SKILL.md").read_text()
    step = re.search(
        r"^### Step 2.*?\n(.*?)(?=^### Step 3)", text, re.MULTILINE | re.DOTALL
    )
    assert step, "intake Step 2 not found"
    assert _headings(_first_fence(step.group(1))) == EXPECTED


def test_template_front_matter() -> None:
    front, _ = _front_matter(TEMPLATE.read_text())
    keys = dict(line.split(":", 1) for line in front.splitlines() if ":" in line)
    assert set(keys) == {"name", "about"}
    assert keys["name"].strip()
    assert keys["about"].strip()


def test_template_sets_no_labels() -> None:
    front, _ = _front_matter(TEMPLATE.read_text())
    for key in ("labels", "assignees", "title"):
        assert not re.search(rf"^{key}\s*:", front, re.MULTILINE)


def test_blank_issues_disabled() -> None:
    assert re.search(
        r"^blank_issues_enabled:\s*false\s*$", CONFIG.read_text(), re.MULTILINE
    )


def test_contributing_guide() -> None:
    text = CONTRIBUTING.read_text()
    assert len(text.splitlines()) <= 40
    assert "SECURITY.md" in text
