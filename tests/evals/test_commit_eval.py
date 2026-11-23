"""Eval: the orchestrator's commit-message generator on a stored staged diff.

Each stored case is a staged diff. `Get-CommitMessage` (.github/orchestrator/engines/
Claude.ps1) writes the message with its real prompt, on the model of the CommitMessage
task, and checks the reply against the commit-message rules written beside it, asking
once more when a reply breaks one. The eval reads only whether the engine wrote the
message (`FromEngine`) or the generator fell back: the rules live in the generator.
"""

import pytest
from eval_goldens import load_goldens
from orchestrator_call import run_in_orchestrator

GOLDENS = load_goldens("commit")

# The case's issue: the scope the message must name, and the title of the fallback.
NUMBER = 1
TITLE = "Apply the stored change"

_GENERATE = f"""
    Get-CommitMessage -Diff $env:COMMIT_EVAL_DIFF -Number {NUMBER} -Title '{TITLE}' |
        ConvertTo-Json -Compress
"""


@pytest.mark.eval
@pytest.mark.parametrize("case", GOLDENS, ids=[g["id"] for g in GOLDENS])
def test_commit_message(case) -> None:
    result = run_in_orchestrator(
        _GENERATE, env={"COMMIT_EVAL_DIFF": case["input"]}, timeout=600
    )
    assert result.get("FromEngine") is True, result.get("Message")
