"""Eval: the refine skill's self-grill — the pipeline-side example.

Each golden is an under-specified issue. The grill probe (the skill's own script, so
the eval exercises the real skill prompt) grills it with Claude; the judge scores the
GrillResult against the refine skill's rules (G-Eval), and Tool Correctness checks
Rule 1 — codebase first — from the grill's tool trace.
"""

import json
import subprocess
from pathlib import Path

import pytest
from deepeval.metrics import GEval, ToolCorrectnessMetric
from deepeval.test_case import LLMTestCase, SingleTurnParams, ToolCall
from eval_goldens import load_goldens

pytestmark = pytest.mark.eval

REPO_ROOT = Path(__file__).resolve().parents[2]
GRILL = REPO_ROOT / ".agents" / "skills" / "refine" / "scripts" / "grill.ps1"
GOLDENS = load_goldens("refine")


def grill(title: str, body: str) -> dict:
    """Run the probe with -Trace: { result: GrillResult, tools_called: [...] }."""
    out = subprocess.run(
        [
            "pwsh",
            "-NoProfile",
            "-File",
            str(GRILL),
            "-Title",
            title,
            "-Body",
            body,
            "-Trace",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=REPO_ROOT,
        timeout=900,
        check=False,
    )
    assert out.returncode == 0, out.stderr or out.stdout
    return json.loads(out.stdout[out.stdout.index("{") :])


def tool_call(name: str) -> ToolCall:
    # Tool Correctness compares names only; input_parameters is optional in DeepEval
    # but its pydantic alias makes type checkers read it as required.
    return ToolCall(name=name, input_parameters=None)


def refine_rules(judge) -> GEval:
    return GEval(
        name="Refine rules",
        # Mirrors refine/SKILL.md Rules 1, 2 and 4 and its multiple-choice format. Each
        # step says what is *intended* too, so the judge does not mark the design down.
        evaluation_steps=[
            (
                "Every open question has a recommended answer in `decision`, with its "
                "reason. An open question has no decider yet: a null `decided_by` is "
                "expected."
            ),
            (
                "Every open question offers two genuine alternatives in `alternatives`, "
                "each with its trade-off. A recommendation plus two alternatives is the "
                "intended multiple-choice format (A recommended, B, C)."
            ),
            (
                "The agent_brief names no source-code paths or line numbers (such as "
                "`src/...`, `*.py`, `*.ps1`). Naming project documents such as "
                "CONTEXT.md or an ADR number is allowed."
            ),
            (
                "Every decided question states the evidence it rests on: the code, "
                "existing behaviour, an ADR, or a documented project constraint."
            ),
            (
                "Judge only the steps above; how many questions are open versus decided "
                "is not a criterion."
            ),
        ],
        evaluation_params=[SingleTurnParams.INPUT, SingleTurnParams.ACTUAL_OUTPUT],
        model=judge,
        threshold=0.7,
    )


@pytest.mark.parametrize("golden", GOLDENS, ids=["rate-limit", "cache", "logs"])
def test_refine_grill(golden, judge, evaluate) -> None:
    title = golden["additional_metadata"]["title"]
    run = grill(title, golden["input"])
    case = LLMTestCase(
        input=f"{title}\n\n{golden['input']}",
        actual_output=json.dumps(run["result"], indent=2),
        tools_called=[tool_call(name) for name in run["tools_called"]],
        expected_tools=[tool_call(tool["name"]) for tool in golden["expected_tools"]],
    )
    evaluate(
        case, [refine_rules(judge), ToolCorrectnessMetric(model=judge, threshold=0.7)]
    )
