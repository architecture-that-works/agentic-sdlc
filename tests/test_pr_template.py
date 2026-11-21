"""The pull request template is the one place a PR's sections are written (#375)."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md"
EXPECTED = ["Summary", "Left undone", "Issues discovered", "Validation"]


def _lines() -> list[str]:
    return TEMPLATE.read_text(encoding="utf-8").splitlines()


def test_four_sections_in_order_each_with_one_comment_line() -> None:
    lines = _lines()
    headings = [(i, line[3:]) for i, line in enumerate(lines) if line.startswith("#")]
    assert [name for _, name in headings] == EXPECTED
    for i, name in headings:
        assert re.fullmatch(r"<!-- .+ -->", lines[i + 1]), f"{name}: no comment line"
        assert lines[i + 2].strip() == "", f"{name}: more than one comment line"


def test_top_comment_names_what_github_enforces() -> None:
    text = TEMPLATE.read_text(encoding="utf-8")
    assert text.startswith("<!--")
    top = text[: text.index("-->")]
    for check in ("lint", "typecheck", "test", "audit", "checks", "eval"):
        assert check in top
    assert "Squash" in top and "title" in top


def test_template_ends_with_a_closes_line() -> None:
    assert [line for line in _lines() if line.strip()][-1] == "Closes #"


def test_contributor_documents_name_the_template() -> None:
    for rel in (
        "CONTRIBUTING.md",
        ".agents/skills/ship/SKILL.md",
        ".agents/skills/ship/REFERENCE.md",
    ):
        assert ".github/PULL_REQUEST_TEMPLATE.md" in (ROOT / rel).read_text(), rel
