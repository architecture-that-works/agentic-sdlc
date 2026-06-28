"""
LLM-optimized error formatter for the verification loop.

Converts raw stderr, pytest failure output, and linter output into a compact
Markdown block that surfaces the error class, salient frames, failing assertion,
and a one-line likely cause — while preserving the full output in a collapsible
<details> block (never truncated).

Kill criterion (issue #119): if the <details> block ever omits a line present
in the raw input, disable the wrapper and fall back to the raw code block.

Callable as a library : format_error(raw: str) -> str
Callable as a CLI     : echo "raw" | uv run python -m src.utils.m_error_formatter
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field

# Number of frames to surface in the summary (full output always in <details>)
_SALIENT_FRAME_COUNT = 5

_FRAME_RE = re.compile(r'^\s*File "(.+?)", line (\d+), in (.+)\s*$')
_FAILED_RE = re.compile(r"^FAILED .+ - (\w[\w.]*)\s*(?::\s*(.+))?$")
_EXCEPTION_SUFFIX = re.compile(
    r"^(\w[\w.]*)(?:Error|Exception|Warning|Fault|Failure|Interrupt|Exit|Stop)"
    r"\s*(?::\s*(.*))?$",
)
_PYTEST_E_RE = re.compile(r"^E\s+(.+)$", re.MULTILINE)
_RUFF_VIOLATION_RE = re.compile(
    r"^(.+?):(\d+):(\d+):\s+([A-Z]\d+)\s+(.+)$",
    re.MULTILINE,
)


@dataclass
class _Parsed:
    error_class: str = "Error"
    message: str = ""
    frames: list[str] = field(default_factory=list)
    assertion: str | None = None
    likely_cause: str = ""


def _detect_error_class(lines: list[str]) -> tuple[str, str]:
    """Return (error_class, message) by scanning lines newest-first."""
    for line in reversed(lines):
        m = _FAILED_RE.match(line.strip())
        if m:
            return m.group(1), (m.group(2) or "").strip()

    for line in reversed(lines):
        candidate = line.strip()
        if candidate.startswith("E ") or candidate.startswith("E\t"):
            candidate = candidate[1:].strip()
        for pattern in (
            _EXCEPTION_SUFFIX,
            re.compile(r"^(\w[\w.]*)(?:Error|Exception)\s*(?::\s*(.*))?$"),
        ):
            m = pattern.match(candidate)
            if m:
                cls = m.group(0).split(":")[0].strip().split()[-1]
                msg_start = candidate.find(":")
                msg = candidate[msg_start + 1 :].strip() if msg_start != -1 else ""
                return cls, msg

    return "Error", ""


def _likely_cause(error_class: str, message: str, assertion: str | None) -> str:
    raw_hint = assertion or message or ""
    hint = raw_hint.splitlines()[0][:120] if raw_hint.splitlines() else ""
    if error_class == "AssertionError":
        return f"Assertion failed: {hint}" if hint else "Assertion failed"
    if error_class in ("ImportError", "ModuleNotFoundError"):
        return f"Missing or broken import: {message[:120]}"
    if error_class == "AttributeError":
        return f"Attribute access on wrong type: {message[:120]}"
    if error_class == "TypeError":
        return f"Wrong argument type or count: {message[:120]}"
    if error_class == "ValueError":
        return f"Invalid value: {message[:120]}"
    if error_class == "LintError":
        return f"Linter violations: {message}"
    if message:
        return f"{error_class}: {message[:120]}"
    return error_class


def _parse_traceback(raw: str) -> _Parsed:
    p = _Parsed()
    lines = raw.splitlines()

    p.error_class, p.message = _detect_error_class(lines)

    frames: list[str] = []
    for i, line in enumerate(lines):
        m = _FRAME_RE.match(line)
        if m:
            code = lines[i + 1].strip() if i + 1 < len(lines) else ""
            frames.append(
                f'  File "{m.group(1)}", line {m.group(2)}, in {m.group(3)}\n    {code}'
            )
    p.frames = frames[-_SALIENT_FRAME_COUNT:]

    e_lines = _PYTEST_E_RE.findall(raw)
    if e_lines:
        p.assertion = "\n".join(e_lines)

    p.likely_cause = _likely_cause(p.error_class, p.message, p.assertion)
    return p


def _parse_ruff(raw: str) -> _Parsed | None:
    violations = _RUFF_VIOLATION_RE.findall(raw)
    if not violations:
        return None
    p = _Parsed()
    p.error_class = "LintError"
    p.message = f"{len(violations)} violation(s)"
    p.frames = [
        f"  {v[0]}:{v[1]}:{v[2]}: {v[3]} {v[4]}"
        for v in violations[:_SALIENT_FRAME_COUNT]
    ]
    if violations:
        first = violations[0]
        p.likely_cause = f"Linter: {first[3]} {first[4]} ({first[0]}:{first[1]})"
    else:
        p.likely_cause = _likely_cause("LintError", p.message, None)
    return p


def format_error(raw: str) -> str:
    """
    Format raw error output as a compact Markdown block for the verification loop.

    The full raw output is preserved verbatim inside a collapsible <details> block;
    the summary section surfaces only the salient fields for fast LLM consumption.
    This function never truncates the raw input (kill criterion: issue #119).

    Parameters
    ----------
    raw : str
        Raw stderr, pytest failure output, or ruff linter output.

    Returns
    -------
    str
        Structured Markdown block, or empty string when raw is empty.
    """
    raw = raw.strip()
    if not raw:
        return ""

    has_traceback = bool(
        re.search(
            r"Traceback \(most recent call last\)|^FAILED .+ - |^ERROR ",
            raw,
            re.MULTILINE,
        )
    )

    if has_traceback:
        parsed = _parse_traceback(raw)
        ruff = _parse_ruff(raw)
        if ruff and ruff.frames:
            parsed.frames = ruff.frames + parsed.frames
    else:
        ruff = _parse_ruff(raw)
        parsed = ruff if ruff is not None else _parse_traceback(raw)

    parts: list[str] = []
    parts.append(f"**Error class:** `{parsed.error_class}`  ")
    parts.append(f"**Likely cause:** {parsed.likely_cause}")
    parts.append("")

    if parsed.frames:
        parts.append("**Salient frames**")
        parts.append("```")
        parts.append("\n".join(parsed.frames[-_SALIENT_FRAME_COUNT:]))
        parts.append("```")
        parts.append("")

    if parsed.assertion:
        parts.append("**Failing assertion / error detail**")
        parts.append("```")
        parts.append(parsed.assertion)
        parts.append("```")
        parts.append("")

    parts.append("<details>")
    parts.append("<summary>Full output (expand for debugging)</summary>")
    parts.append("")
    parts.append("```text")
    parts.append(raw)
    parts.append("```")
    parts.append("")
    parts.append("</details>")

    return "\n".join(parts)


if __name__ == "__main__":
    print(format_error(sys.stdin.read()))
