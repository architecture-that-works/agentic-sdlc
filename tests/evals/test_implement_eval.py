"""Eval: the implement skill's closing note — the checked answer the orchestrator reads.

Each stored case is a finished mini-task: what was done, skipped and noticed. The model
writes the closing note the way the implement stage starts it: through the engine
function `Invoke-EngineTask`, on the `ImplementLarge` task, one-shot with no tools, with
the skill's SKILL.md at the head of the prompt and the skill's `answer.schema.json` as
the schema — the schema the implement stage passes too. The note is read the way
`stages/Implement.ps1` reads it: the checked lists of the result's `Answer`, only when
its `Outcome` is `finished`. A case flags what it names: `skipped` means `left_undone`
must hold an item, `noticed` means `issues_discovered` must.
"""

import json
from pathlib import Path

import pytest
from eval_goldens import load_goldens
from orchestrator_call import engine_task

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / ".agents/skills/implement"
SKILL = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
SCHEMA = (SKILL_DIR / "answer.schema.json").read_text(encoding="utf-8")
GOLDENS = load_goldens("implement")
FIELDS = ("implemented", "left_undone", "issues_discovered")


def note_of(result: dict) -> dict | None:
    """The closing note the implement stage reads: `Answer`, with every list.

    None unless the run finished with a checked answer.
    """
    if result.get("Outcome") != "finished":
        return None
    answer = result.get("Answer")
    if not isinstance(answer, dict):
        return None
    if not all(isinstance(answer.get(field), list) for field in FIELDS):
        return None
    return answer


def unmet(result: dict, case: dict) -> list[str]:
    """What the result lacks for the case; empty when it passes.

    The implement stage fails the attempt on a result without a checked answer, so a
    missing note is always unmet.
    """
    note = note_of(result)
    if note is None:
        return ["a checked answer with every list"]
    wanted = {
        "left_undone": case.get("skipped"),
        "issues_discovered": case.get("noticed"),
    }
    return [field for field, named in wanted.items() if named and not note[field]]


def closing_note(task: str) -> dict:
    prompt = (
        f"{SKILL}\n\n---\n\n"
        "The task below is finished. Give the closing note your skill asks for "
        f"at the end of a task.\n\n{task}"
    )
    return engine_task("ImplementLarge", prompt, SCHEMA)


@pytest.mark.eval
@pytest.mark.parametrize("case", GOLDENS, ids=[g["id"] for g in GOLDENS])
def test_closing_note(case) -> None:
    result = closing_note(case["input"])
    missing = unmet(result, case)
    assert missing == [], f"{missing} missing from:\n{json.dumps(result, indent=2)}"


def _finished(answer) -> dict:
    return {"Outcome": "finished", "Answer": answer, "Cause": None}


def test_unmet_reads_the_checked_lists_the_implement_stage_reads() -> None:
    case = {"skipped": True, "noticed": True}
    full = _finished(
        {
            "implemented": ["clamp with tests"],
            "left_undone": ["lo > hi is not handled"],
            "issues_discovered": ["README.md documents clamp_value"],
        }
    )
    assert unmet(full, case) == []
    silent = _finished(
        {
            "implemented": ["clamp with tests"],
            "left_undone": [],
            "issues_discovered": [],
        }
    )
    assert unmet(silent, case) == ["left_undone", "issues_discovered"]
    assert unmet(silent, {}) == []


def test_a_result_without_a_checked_answer_is_unmet() -> None:
    case = {"skipped": False, "noticed": False}
    no_answer = {"Outcome": "failed", "Answer": None, "Cause": "no checked answer"}
    partial = _finished({"implemented": ["clamp"], "left_undone": []})
    not_an_object = _finished("Left undone: none")
    assert unmet(no_answer, case) == ["a checked answer with every list"]
    assert unmet(partial, case) == ["a checked answer with every list"]
    assert unmet(not_an_object, case) == ["a checked answer with every list"]


def test_a_run_that_did_not_finish_is_unmet() -> None:
    answer = {"implemented": ["clamp"], "left_undone": [], "issues_discovered": []}
    for outcome in ("failed", "max_turns"):
        result = {"Outcome": outcome, "Answer": answer, "Cause": "ran out"}
        assert unmet(result, {}) == ["a checked answer with every list"]
