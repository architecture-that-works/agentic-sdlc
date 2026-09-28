"""Golden datasets for evals: JSONL beside the tests, one DeepEval golden per line.

Fields follow DeepEval's Golden (input, expected_output, context, expected_tools, …) —
nothing bespoke, so the files stay portable to any tool that reads DeepEval goldens.
"""

import json
from pathlib import Path

GOLDENS_DIR = Path(__file__).parent / "goldens"


def load_goldens(name: str) -> list[dict]:
    lines = (GOLDENS_DIR / f"{name}.jsonl").read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]
