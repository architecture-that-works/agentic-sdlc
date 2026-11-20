"""Invariant: dual-use root files and their Jinja2 twins agree on the header.

A root file with a `.jinja2` twin is dual-use (`copier.yml` comment): the plain file is
the template repo's own and the twin is the project's day-one copy. The template-only
section — format documentation, header fields, scales — must be identical, so the format
a project learns on day one is the same one the template repo's tooling (`task sync`)
parses. Only the entries below each boundary diverge.
"""

from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.parent

ISSUES_SENTINEL = "<!-- ISSUES -->"
OOS_FIRST_ENTRY_PREFIX = "## "


def test_issues_md_and_twin_match_through_sentinel() -> None:
    plain = (REPO_ROOT / "ISSUES.md").read_text(encoding="utf-8")
    twin = (REPO_ROOT / "ISSUES.md.jinja2").read_text(encoding="utf-8")

    sentinel_in_plain = plain.find(ISSUES_SENTINEL)
    sentinel_in_twin = twin.find(ISSUES_SENTINEL)
    assert sentinel_in_plain != -1, f"{ISSUES_SENTINEL!r} missing from ISSUES.md"
    assert sentinel_in_twin != -1, f"{ISSUES_SENTINEL!r} missing from ISSUES.md.jinja2"

    end_plain = sentinel_in_plain + len(ISSUES_SENTINEL)
    end_twin = sentinel_in_twin + len(ISSUES_SENTINEL)
    assert plain[:end_plain] == twin[:end_twin], (
        "ISSUES.md and ISSUES.md.jinja2 diverge before/at the sentinel — "
        "the dual-use header must match."
    )


def test_out_of_scope_md_and_twin_match_above_first_entry() -> None:
    plain = (REPO_ROOT / ".out-of-scope.md").read_text(encoding="utf-8")
    twin = (REPO_ROOT / ".out-of-scope.md.jinja2").read_text(encoding="utf-8")

    # First ## header starts the rejection ledger entries; everything above is intro.
    def header_at(text: str) -> int:
        for idx, line in enumerate(text.splitlines(keepends=True)):
            if line.startswith(OOS_FIRST_ENTRY_PREFIX):
                return sum(len(l) for l in text.splitlines(keepends=True)[:idx])
        return len(text)

    plain_intro = plain[: header_at(plain)]
    twin_intro = twin[: header_at(twin)]
    assert plain_intro == twin_intro, (
        ".out-of-scope.md and .out-of-scope.md.jinja2 diverge above the first '## ' entry "
        "— the dual-use intro must match."
    )
