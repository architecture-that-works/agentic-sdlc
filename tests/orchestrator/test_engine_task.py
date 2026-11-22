"""Invoke-EngineTask — the one function that starts a model (engines/Claude.ps1).

The function runs against a stand-in `claude` executable put first on PATH. The
stand-in records the arguments and the prompt of every start, and replays one canned
attempt per start: the lines it prints and the exit code it ends with. So the test
sees the real command line the function builds, not a PowerShell stub's view of it.

Asserted: the model, both tool flags and the turn budget a call is started with; a
one-shot call starts with no tools; a run that ends on its turn budget is reported and
not retried; a failed call is retried; a spent usage allowance is not; refused edits,
the tools called and the checked answer come back in the returned object; the CLI's
noise lines are stripped; and the module stops at import when the Engine setting names
no adapter.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

PWSH = shutil.which("pwsh") or "pwsh"
REPO_ROOT = Path(__file__).parents[2]
MODULE = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"

pytestmark = [
    pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available"),
    pytest.mark.skipif(os.name == "nt", reason="the stand-in CLI is a shebang script"),
]

_STANDIN = """#!{python}
import json, os, sys
d = os.environ["STANDIN_DIR"]
attempts = json.load(open(os.path.join(d, "attempts.json"), encoding="utf-8"))
calls_path = os.path.join(d, "calls.jsonl")
n = sum(1 for _ in open(calls_path, encoding="utf-8")) if os.path.exists(calls_path) else 0
with open(calls_path, "a", encoding="utf-8") as f:
    f.write(json.dumps({{"argv": sys.argv[1:], "prompt": sys.stdin.read()}}) + "\\n")
attempt = attempts[min(n, len(attempts) - 1)]
for line in attempt.get("lines", []):
    print(line, flush=True)
for line in attempt.get("stderr", []):
    print(line, file=sys.stderr, flush=True)
sys.exit(attempt.get("exit", 0))
"""


def _standin(tmp_path: Path, attempts: list[dict]) -> dict:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    cli = bindir / "claude"
    cli.write_text(_STANDIN.format(python=sys.executable), encoding="utf-8")
    cli.chmod(0o755)
    (tmp_path / "attempts.json").write_text(json.dumps(attempts), encoding="utf-8")
    return {
        **os.environ,
        "PATH": f"{bindir}{os.pathsep}{os.environ.get('PATH', '')}",
        "STANDIN_DIR": str(tmp_path),
        "GITHUB_REPOSITORY": "octocat/sandbox",
        "GITHUB_DEFAULT_BRANCH": "main",
    }


def _calls(tmp_path: Path) -> list[dict]:
    path = tmp_path / "calls.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def _run(tmp_path: Path, attempts: list[dict], body: str) -> dict:
    """Run `body` in the module's session state against the stand-in; it prints one
    JSON line last."""
    work = tmp_path / "work"
    work.mkdir(exist_ok=True)
    script = (
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) {\n"
        "function script:Write-Log { param($Message, $Color) }\n"
        "$script:Sleeps = [System.Collections.Generic.List[int]]::new()\n"
        "function script:Start-Sleep { param([int]$Seconds) $script:Sleeps.Add($Seconds) }\n"
        f"{body}\n"
        "}\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        cwd=work,
        env=_standin(tmp_path, attempts),
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


_REPORT = r"""
[pscustomobject]@{
    model   = $model
    outcome = $r.Outcome
    reply   = $r.Reply
    tools   = @($r.ToolsCalled)
    refused = @($r.RefusedEdits)
    answer  = $r.Answer
    output  = $r.Output
    cause   = $r.Cause
    sleeps  = @($script:Sleeps)
    seen    = @($script:Seen)
} | ConvertTo-Json -Compress -Depth 6
"""


def _result(**fields) -> str:
    return json.dumps({"type": "result", **fields})


def _assistant(*blocks: dict) -> str:
    return json.dumps({"type": "assistant", "message": {"content": list(blocks)}})


def _tool(name: str, **tool_input) -> dict:
    return {"type": "tool_use", "id": name, "name": name, "input": tool_input}


def _flag(argv: list[str], name: str) -> str:
    return argv[argv.index(name) + 1]


# ── The command line ──────────────────────────────────────────────────────────


def test_an_agentic_call_starts_with_the_task_model_both_tool_flags_and_the_budget(
    tmp_path: Path,
) -> None:
    out = _run(
        tmp_path,
        [{"lines": [_result(subtype="success", result="done", structured_output={})]}],
        r"""
$model = Get-TaskModel -Task 'Review'
$r = Invoke-EngineTask -Task 'Review' -Prompt 'look at this' -Label 'Review' `
    -Tools 'Read', 'Glob', 'Grep' -MaxTurns 35 -Schema '{"type":"object"}'
"""
        + _REPORT,
    )
    calls = _calls(tmp_path)
    assert len(calls) == 1
    argv = calls[0]["argv"]
    assert _flag(argv, "--model") == out["model"]
    assert _flag(argv, "--tools") == "Read,Glob,Grep"
    assert _flag(argv, "--allowedTools") == _flag(argv, "--tools")
    assert _flag(argv, "--max-turns") == "35"
    assert _flag(argv, "--output-format") == "stream-json"
    assert "--verbose" in argv and "-p" in argv
    assert _flag(argv, "--json-schema") == '{"type":"object"}'
    assert calls[0]["prompt"].strip() == "look at this"
    assert out["outcome"] == "finished"
    assert out["reply"] == "done"


def test_a_one_shot_call_starts_with_no_tools_and_no_turn_budget(
    tmp_path: Path,
) -> None:
    out = _run(
        tmp_path,
        [{"lines": [_result(subtype="success", result="feat: x")]}],
        r"""
$model = Get-TaskModel -Task 'CommitMessage'
$r = Invoke-EngineTask -Task 'CommitMessage' -Prompt 'diff' -Label 'Commit message'
"""
        + _REPORT,
    )
    argv = _calls(tmp_path)[0]["argv"]
    assert _flag(argv, "--model") == out["model"]
    assert _flag(argv, "--tools") == ""
    assert "--allowedTools" not in argv
    assert "--max-turns" not in argv
    assert "--json-schema" not in argv
    assert out["reply"] == "feat: x"
    assert out["answer"] is None


def test_tools_without_a_turn_budget_is_refused(tmp_path: Path) -> None:
    out = _run(
        tmp_path,
        [{"lines": [_result(subtype="success", result="x")]}],
        r"""
$err = $null
try { Invoke-EngineTask -Task 'Review' -Prompt 'p' -Label 'Review' -Tools 'Read' } catch { $err = $_.Exception.Message }
[pscustomobject]@{ err = $err } | ConvertTo-Json -Compress
""",
    )
    assert "-Tools and -MaxTurns come together" in out["err"]
    assert _calls(tmp_path) == []


# ── How the run ended ─────────────────────────────────────────────────────────


def test_a_run_that_ends_on_its_turn_budget_is_reported_and_not_retried(
    tmp_path: Path,
) -> None:
    out = _run(
        tmp_path,
        [{"lines": [_result(subtype="error_max_turns", is_error=True)], "exit": 1}],
        r"""
$r = Invoke-EngineTask -Task 'Review' -Prompt 'p' -Label 'Review' -Tools 'Read' -MaxTurns 30
"""
        + _REPORT,
    )
    assert out["outcome"] == "max_turns"
    assert "ran out of turns (30)" in out["cause"]
    assert len(_calls(tmp_path)) == 1
    assert out["sleeps"] == []


def test_a_failed_call_is_retried_and_the_second_answer_comes_back(
    tmp_path: Path,
) -> None:
    answer = {"verdict": "approved", "report": "ok"}
    out = _run(
        tmp_path,
        [
            {"lines": ["API Error: 529 overloaded"], "exit": 1},
            {"lines": [_result(subtype="success", structured_output=answer)]},
        ],
        r"""
$r = Invoke-EngineTask -Task 'Review' -Prompt 'p' -Label 'Review' -Tools 'Read' -MaxTurns 30 -Schema '{}'
"""
        + _REPORT,
    )
    assert len(_calls(tmp_path)) == 2
    assert out["sleeps"] == [20]
    assert out["outcome"] == "finished"
    assert out["answer"] == answer


def test_a_call_that_keeps_failing_ends_as_failed_without_a_throw(
    tmp_path: Path,
) -> None:
    out = _run(
        tmp_path,
        [{"lines": ["boom"], "exit": 1}],
        "$r = Invoke-EngineTask -Task 'Plan' -Prompt 'p' -Label 'Plan'\n" + _REPORT,
    )
    assert len(_calls(tmp_path)) == 3
    assert out["sleeps"] == [20, 40]
    assert out["outcome"] == "failed"
    assert "exited 1" in out["cause"]
    assert "boom" in out["output"]


def test_a_spent_usage_allowance_is_not_retried(tmp_path: Path) -> None:
    out = _run(
        tmp_path,
        [
            {
                "lines": [
                    _result(
                        subtype="success",
                        is_error=True,
                        result="Claude AI usage limit reached|1900000000",
                    )
                ],
                "exit": 1,
            }
        ],
        "$r = Invoke-EngineTask -Task 'EngineCheck' -Prompt 'ping' -Label 'Engine check'\n"
        + _REPORT,
    )
    assert len(_calls(tmp_path)) == 1
    assert out["sleeps"] == []
    assert out["outcome"] == "failed"
    assert "usage limit" in out["cause"]


@pytest.mark.parametrize(
    ("event", "exit_code", "cause"),
    [
        (_result(subtype="success", result="APPROVED"), 0, "no structured_output"),
        (
            _result(subtype="error_max_structured_output_retries", is_error=True),
            1,
            "error_max_structured_output_retries",
        ),
    ],
    ids=["no-structured-output", "max-structured-output-retries"],
)
def test_a_run_without_a_checked_answer_fails_once(
    tmp_path: Path, event: str, exit_code: int, cause: str
) -> None:
    out = _run(
        tmp_path,
        [{"lines": [event], "exit": exit_code}],
        r"""
$r = Invoke-EngineTask -Task 'Review' -Prompt 'p' -Label 'Review' -Tools 'Read' -MaxTurns 30 -Schema '{}'
"""
        + _REPORT,
    )
    assert out["outcome"] == "failed"
    assert cause in out["cause"]
    assert len(_calls(tmp_path)) == 1


# ── What the run did ─────────────────────────────────────────────────────────


def test_refused_edits_come_back_repo_relative_and_only_for_edits(
    tmp_path: Path,
) -> None:
    work = tmp_path / "work"
    denials = [
        {"tool_name": "Bash", "tool_input": {"command": "rm -rf .claude"}},
        {
            "tool_name": "Edit",
            "tool_input": {"file_path": str(work / ".devcontainer" / "x.json")},
        },
        {"tool_name": "Write", "tool_input": {"file_path": ".mcp.json"}},
        {"tool_name": "NotebookEdit", "tool_input": {"notebook_path": "./nb.ipynb"}},
        {"tool_name": "Edit", "tool_input": {"file_path": ".mcp.json"}},
    ]
    out = _run(
        tmp_path,
        [
            {
                "lines": [
                    _result(
                        subtype="success", result="done", permission_denials=denials
                    )
                ]
            }
        ],
        r"""
$r = Invoke-EngineTask -Task 'ImplementSmall' -Prompt 'p' -Label 'Implement' -Tools 'Edit' -MaxTurns 5
"""
        + _REPORT,
    )
    assert out["refused"] == [".devcontainer/x.json", ".mcp.json", "nb.ipynb"]


def test_tool_calls_reach_the_callback_and_the_list_without_structured_output(
    tmp_path: Path,
) -> None:
    out = _run(
        tmp_path,
        [
            {
                "lines": [
                    json.dumps({"type": "system", "subtype": "init"}),
                    _assistant(
                        {"type": "text", "text": "Reading first."},
                        _tool("Read", file_path="AGENTS.md"),
                        _tool("Bash", command="uv run pytest"),
                    ),
                    _assistant(_tool("StructuredOutput", verdict="approved")),
                    _result(subtype="success", structured_output={"verdict": "x"}),
                ]
            }
        ],
        r"""
$script:Seen = [System.Collections.Generic.List[string]]::new()
$r = Invoke-EngineTask -Task 'Review' -Prompt 'p' -Label 'Review' -Tools 'Read', 'Bash' -MaxTurns 5 -Schema '{}' `
    -OnToolCall { param($call) $script:Seen.Add("$($call.Name)=$($call.Input.file_path)$($call.Input.command)"); 'ignored output' }
"""
        + _REPORT,
    )
    assert out["tools"] == ["Read", "Bash"]
    assert out["seen"] == ["Read=AGENTS.md", "Bash=uv run pytest"]
    assert out["answer"] == {"verdict": "x"}


def test_the_cli_noise_lines_are_stripped(tmp_path: Path) -> None:
    out = _run(
        tmp_path,
        [
            {
                "lines": [_result(subtype="success", result="feat: y")],
                "stderr": [
                    "Warning: permissions.allow entries are ignored on an untrusted workspace",
                    "set hasTrustDialogAccepted to trust it",
                    "a real warning",
                ],
            }
        ],
        "$r = Invoke-EngineTask -Task 'CommitMessage' -Prompt 'p' -Label 'Commit'\n"
        + _REPORT,
    )
    assert "permissions.allow" not in out["output"]
    assert "hasTrustDialogAccepted" not in out["output"]
    assert "a real warning" in out["output"]
    assert out["reply"] == "feat: y"


def test_a_cli_that_cannot_start_fails_without_a_retry(tmp_path: Path) -> None:
    out = _run(
        tmp_path,
        [{"lines": []}],
        r"""
function script:claude { throw "The term 'claude' is not recognized" }
$r = Invoke-EngineTask -Task 'EngineCheck' -Prompt 'ping' -Label 'Engine check'
"""
        + _REPORT,
    )
    assert out["outcome"] == "failed"
    assert "could not run" in out["cause"]
    assert out["sleeps"] == []


# ── The commit message ───────────────────────────────────────────────────────


def test_the_commit_message_falls_back_when_the_engine_fails(tmp_path: Path) -> None:
    out = _run(
        tmp_path,
        [{"lines": ["boom"], "exit": 1}],
        r"""
[pscustomobject]@{ msg = (Get-CommitMessage -Diff 'd' -FallbackMessage 'feat(#1): t') } | ConvertTo-Json -Compress
""",
    )
    assert out["msg"] == "feat(#1): t"


# ── The adapter the Engine setting names ─────────────────────────────────────


def test_the_module_stops_at_import_when_the_engine_has_no_adapter(
    tmp_path: Path,
) -> None:
    copy = tmp_path / "orchestrator"
    shutil.copytree(MODULE.parent, copy)
    config = copy / "lib" / "Config.ps1"
    text = config.read_text(encoding="utf-8")
    assert "Engine = 'claude'" in text
    config.write_text(text.replace("Engine = 'claude'", "Engine = 'other'"), "utf-8")
    result = subprocess.run(
        [
            PWSH,
            "-NoProfile",
            "-Command",
            f"Import-Module '{copy / 'Orchestrator.psd1'}' -Force -DisableNameChecking",
        ],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        env={
            **os.environ,
            "GITHUB_REPOSITORY": "octocat/sandbox",
            "GITHUB_DEFAULT_BRANCH": "main",
        },
        check=False,
    )
    assert result.returncode != 0 or "names no engine adapter" in result.stderr
    assert "names no engine adapter" in result.stdout + result.stderr


# ── Nothing outside the adapter knows the CLI ────────────────────────────────

_ADAPTER = REPO_ROOT / ".github" / "orchestrator" / "engines" / "Claude.ps1"
_FLAG = re.compile(
    r"--(model|allowedTools|tools|max-turns|output-format|json-schema)\b"
)
_START = re.compile(r"\|\s*claude\b|claude @")


def _sources(*roots: Path) -> list[Path]:
    return [
        p
        for root in roots
        for p in root.rglob("*")
        if p.is_file() and p.suffix in {".ps1", ".psm1", ".psd1", ".yml", ".md"}
    ]


def test_only_the_engine_adapter_starts_the_cli_or_names_its_flags() -> None:
    orchestrator = REPO_ROOT / ".github" / "orchestrator"
    offenders = [
        f"{p.relative_to(REPO_ROOT)}:{i}"
        for p in _sources(orchestrator, REPO_ROOT / ".agents")
        if p != _ADAPTER
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1)
        if _FLAG.search(line) or _START.search(line)
    ]
    assert offenders == []
    pins = [
        p
        for p in _sources(REPO_ROOT / ".github")
        if "-Engine 'claude'" in p.read_text(encoding="utf-8")
    ]
    assert pins == []
