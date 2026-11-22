"""The issue template is the one place an issue's headings are written (#369)."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / ".github" / "ISSUE_TEMPLATE" / "issue.md"
CONFIG = ROOT / ".github" / "ISSUE_TEMPLATE" / "config.yml"
CONTRIBUTING = ROOT / "CONTRIBUTING.md"
HEADING = re.compile(r"^\*\*([^*]+)\*\*:", re.MULTILINE)


def _headings(text: str) -> list[str]:
    return HEADING.findall(text)


def _front_matter(text: str) -> tuple[str, str]:
    match = re.match(r"\A---\n(.*?)\n---\n(.*)\Z", text, re.DOTALL)
    assert match, "issue template must start with YAML front matter"
    return match.group(1), match.group(2)


def test_issues_md_does_not_repeat_the_headings() -> None:
    """ISSUES.md points to the template; above its sentinel it spells no heading."""
    _, body = _front_matter(TEMPLATE.read_text())
    text = (ROOT / "ISSUES.md").read_text()
    sentinel = re.search(r"^<!-- ISSUES -->\s*$", text, re.MULTILINE)
    assert sentinel, "ISSUES.md sentinel not found"
    header = text[: sentinel.start()]
    for name in _headings(body):
        assert f"**{name}**:" not in header, f"ISSUES.md repeats the heading {name!r}"


def test_no_heading_spelled_in_orchestrator_or_commands() -> None:
    """The orchestrator and the commands read the headings; they never spell one."""
    _, body = _front_matter(TEMPLATE.read_text())
    hits = [
        f"{path.relative_to(ROOT)}: **{name}**"
        for folder in (ROOT / ".github" / "orchestrator", ROOT / ".github" / "tasks")
        for path in sorted(folder.rglob("*"))
        if path.is_file()
        for name in _headings(body)
        if f"**{name}**" in path.read_text(encoding="utf-8", errors="ignore")
    ]
    assert not hits, hits


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
