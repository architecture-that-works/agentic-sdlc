import subprocess
import sys

import pytest

from src.utils.m_error_formatter import format_error

_PYTEST_FAILURE = """\
FAILED tests/test_foo.py::test_something - AssertionError: assert False == True
========================= short test summary info ==========================
Traceback (most recent call last):
  File "tests/test_foo.py", line 42, in test_something
    assert result == expected
E   AssertionError: assert False == True
E   assert False == True
"""

_RUFF_OUTPUT = """\
src/foo.py:1:1: E302 Expected 2 blank lines, found 1
src/bar.py:10:5: F401 'os' imported but unused
"""

_MIXED_OUTPUT = """\
FAILED tests/test_baz.py::test_bar - ValueError: unexpected value
Traceback (most recent call last):
  File "tests/test_baz.py", line 99, in test_bar
    result = compute()
E   ValueError: unexpected value
src/baz.py:5:1: E501 Line too long (120 > 88)
"""


def test_format_empty_returns_empty():
    assert format_error("") == ""
    assert format_error("   ") == ""


def test_format_pytest_failure_has_error_class():
    result = format_error(_PYTEST_FAILURE)
    assert "AssertionError" in result


def test_format_pytest_failure_has_likely_cause():
    result = format_error(_PYTEST_FAILURE)
    assert "Likely cause" in result


def test_format_pytest_failure_has_salient_frame():
    result = format_error(_PYTEST_FAILURE)
    assert "test_foo.py" in result


def test_format_pytest_failure_preserves_full_traceback():
    result = format_error(_PYTEST_FAILURE)
    assert "<details>" in result
    assert "</details>" in result
    # Every original line must appear verbatim somewhere in the output
    assert "assert False == True" in result
    assert "assert result == expected" in result


def test_format_ruff_output_has_error_class():
    result = format_error(_RUFF_OUTPUT)
    assert "LintError" in result


def test_format_ruff_output_has_likely_cause():
    result = format_error(_RUFF_OUTPUT)
    assert "Linter" in result or "Likely cause" in result


def test_format_ruff_output_preserves_all_violations():
    result = format_error(_RUFF_OUTPUT)
    assert "E302" in result
    assert "F401" in result
    assert "<details>" in result


def test_format_no_truncation_kill_criterion():
    """Kill criterion: every line in raw input must appear in the output."""
    long_raw = "\n".join(f"line {i}: some error detail here" for i in range(500))
    result = format_error(long_raw)
    assert "line 0: some error detail here" in result
    assert "line 499: some error detail here" in result


def test_format_details_block_structure():
    result = format_error(_PYTEST_FAILURE)
    assert "<details>" in result
    assert "<summary>Full output (expand for debugging)</summary>" in result
    assert "</details>" in result


def test_format_mixed_output_preserves_all():
    result = format_error(_MIXED_OUTPUT)
    assert "ValueError" in result
    assert "<details>" in result
    assert "unexpected value" in result
    # Full raw preserved — ruff line is in the output
    assert "E501" in result


def test_format_mixed_output_has_likely_cause():
    result = format_error(_MIXED_OUTPUT)
    assert "Likely cause" in result


def test_main_entry_point_reads_stdin():
    """The __main__ entry point pipes stdin to stdout."""
    proc = subprocess.run(
        [sys.executable, "-m", "src.utils.m_error_formatter"],
        input=_RUFF_OUTPUT,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    assert "LintError" in proc.stdout
    assert "<details>" in proc.stdout


def test_main_entry_point_empty_input():
    proc = subprocess.run(
        [sys.executable, "-m", "src.utils.m_error_formatter"],
        input="",
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""
