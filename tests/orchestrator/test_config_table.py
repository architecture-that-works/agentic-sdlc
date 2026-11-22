"""Contract test for the settings table (#388).

- lib/Config.ps1 — $OrchestratorConfig is the one place every orchestrator setting
  has its value. A key nothing reads is a setting that changes nothing, so every
  top-level key must be read in code as `$OrchestratorConfig.Key` or
  `$OrchestratorConfig['Key']` in a PowerShell file of the orchestrator module or
  its commands. Comments, the `Key =` line in the table and properties of other
  objects do not count.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parents[2]
PWSH = shutil.which("pwsh") or "pwsh"
MODULE = REPO_ROOT / ".github" / "orchestrator" / "Orchestrator.psd1"
SEARCH_ROOTS = (REPO_ROOT / ".github" / "orchestrator", REPO_ROOT / ".github" / "tasks")

pytestmark = pytest.mark.skipif(not shutil.which("pwsh"), reason="pwsh not available")


def _config_keys() -> list[str]:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) { ConvertTo-Json -Compress "
        "-InputObject @($OrchestratorConfig.Keys | Sort-Object) }\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("[")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return json.loads(lines[-1])


def _sources() -> list[Path]:
    files = [
        p
        for root in SEARCH_ROOTS
        for p in root.rglob("*")
        if p.suffix in {".ps1", ".psm1"}
    ]
    assert files
    return files


# Parses each file with PowerShell's own parser and lists the keys read as
# `$OrchestratorConfig.<Key>` or `$OrchestratorConfig['<Key>']`. Comments are not
# part of the syntax tree, and a property of another object (`$ctx.Engine`) has a
# different target, so neither counts as a read of the table.
_READS_SCRIPT = r"""
$reads = [System.Collections.Generic.HashSet[string]]::new()
foreach ($path in ($env:CONFIG_TABLE_FILES | ConvertFrom-Json)) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "parse error in ${path}: $($errors[0].Message)" }
    $found = $ast.FindAll({
        param($n)
        $target = if ($n -is [System.Management.Automation.Language.MemberExpressionAst]) {
            $n.Expression
        } elseif ($n -is [System.Management.Automation.Language.IndexExpressionAst]) {
            $n.Target
        }
        $target -is [System.Management.Automation.Language.VariableExpressionAst] -and
        ($target.VariablePath.UserPath -replace '^\w+:', '') -eq 'OrchestratorConfig'
    }, $true)
    foreach ($n in $found) {
        $key = if ($n -is [System.Management.Automation.Language.MemberExpressionAst]) {
            $n.Member
        } else { $n.Index }
        if ($key -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            [void]$reads.Add($key.Value)
        }
    }
}
ConvertTo-Json -Compress -InputObject @($reads | Sort-Object)
"""


def _keys_read(files: list[Path]) -> set[str]:
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", _READS_SCRIPT],
        env={**os.environ, "CONFIG_TABLE_FILES": json.dumps([str(f) for f in files])},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    lines = [line for line in result.stdout.splitlines() if line.startswith("[")]
    assert lines, f"no JSON output:\n{result.stdout}\n{result.stderr}"
    return set(json.loads(lines[-1]))


def _unread(keys: list[str], files: list[Path]) -> list[str]:
    read = _keys_read(files)
    return [key for key in keys if key not in read]


def test_every_setting_in_the_table_is_read() -> None:
    keys = _config_keys()
    assert "MaxRetries" in keys  # the table loaded, not an empty list
    unread = _unread(keys, _sources())
    assert not unread, f"settings nothing reads: {unread}"


def test_a_comment_or_another_objects_property_is_not_a_read(tmp_path: Path) -> None:
    sample = tmp_path / "Sample.ps1"
    sample.write_text(
        "#Requires -Version 7.0\n"
        "# $OrchestratorConfig.InComment is only mentioned here\n"
        "<# $OrchestratorConfig.InBlockComment #>\n"
        "$x = $ctx.OtherObject\n"
        "$a = $OrchestratorConfig.ByMember\n"
        "$b = $OrchestratorConfig['ByIndex']\n"
        '$c = "$($OrchestratorConfig.InString)"\n',
        encoding="utf-8",
    )
    keys = [
        "InComment",
        "InBlockComment",
        "OtherObject",
        "ByMember",
        "ByIndex",
        "InString",
    ]
    assert _unread(keys, [sample]) == ["InComment", "InBlockComment", "OtherObject"]


def test_the_new_settings_keep_their_values() -> None:
    script = (
        "$env:GITHUB_REPOSITORY = 'octocat/sandbox'\n"
        "$env:GITHUB_DEFAULT_BRANCH = 'main'\n"
        f"Import-Module '{MODULE}' -Force -DisableNameChecking\n"
        "& (Get-Module Orchestrator) { [pscustomobject]@{\n"
        "  pause = $OrchestratorConfig.MaxPauseHours\n"
        "  timeout = $OrchestratorConfig.RequiredChecksTimeoutSeconds\n"
        "  poll = $OrchestratorConfig.RequiredChecksPollSeconds\n"
        "  ctx = @((Get-OrchestratorContext).PSObject.Properties.Name)\n"
        "} | ConvertTo-Json -Compress }\n"
    )
    result = subprocess.run(
        [PWSH, "-NoProfile", "-Command", script],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    out = json.loads(
        [ln for ln in result.stdout.splitlines() if ln.startswith("{")][-1]
    )
    assert (out["pause"], out["timeout"], out["poll"]) == (5, 900, 10)
    assert "MaxRetries" not in out["ctx"]
    assert "RequiredChecks" in out["ctx"]
