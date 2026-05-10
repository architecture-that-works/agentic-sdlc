# ISSUES.md

Local improvement backlog. Add improvements as Agile User Story blocks below the ISSUES sentinel.

Run `task sync` to push pending blocks to GitHub Issues and the project board.
Run `task sync -- -DryRun` to preview without making changes.

---

## Format

Every issue must follow this structure exactly so `sync-issues.ps1` can parse it:

```
ISSUE: [Action-oriented Issue Title]
LABELS: AFK
**Goal**: A singular non-technical explanation of the business outcome.
**Description**: Context answering *why* this matters, linking previous boundaries to the new feature.
**Requirements**:
1. Sequenced, modular actionable steps explicit enough for an independent developer (or AI) to implement.
**Acceptance Criteria**:
- Strict qualitative boundaries defining when the work is officially "finished".
END_ISSUE
```

`LABELS:` is optional. Accepts a comma-separated list of label names. Known labels (`AFK`, `HITL`, `planning`, `enhancement`, `bug`) are auto-created with canonical colours if absent. Unknown labels are created with a grey fallback. The `repo:<repo-name>` label is always applied regardless.

After `task sync`, each processed block is removed from this file and lives as a GitHub Issue on the project board.

---

<!-- ISSUES -->
