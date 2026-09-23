"""Guards for .github/workflows/afk.yml — the unattended pipeline.

Static checks (no gh/pwsh needed) so they run on every CI runner.
"""

import re
from pathlib import Path

WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "afk.yml"


def test_engine_is_pinned_to_an_installed_cli():
    """The cloud runners install only the Claude CLI, so the engine must be pinned.

    Reading `vars.KANBAN_ENGINE` let the repository variable (set to `gemini` for
    local HITL runs) select an engine whose CLI is absent on the runner, and every
    AFK run died in Assert-EngineReady before the refine stage started.
    """
    text = WORKFLOW.read_text(encoding="utf-8")
    code = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    assert "vars.KANBAN_ENGINE" not in code
    engines = re.findall(r"^\s*KANBAN_ENGINE:\s*(\S+)\s*$", code, re.MULTILINE)
    assert engines == ["claude"]
    assert "npm install -g @anthropic-ai/claude-code" in code
