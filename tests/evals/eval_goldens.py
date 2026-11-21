"""Stored cases for evals: JSONL beside the tests, one case per line.

A case holds an `id` and only the fields its eval's check reads (tests/README.md § Evals).
"""

import json
from pathlib import Path

GOLDENS_DIR = Path(__file__).parent / "goldens"


def load_goldens(name: str) -> list[dict]:
    lines = (GOLDENS_DIR / f"{name}.jsonl").read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]
