---
name: intake-reference
description: Deep reference for the intake skill — confirmation-gate decision tree, body schema template, mobile scoping, routing signals
---

# Intake — Reference

## Confirmation-Gate Decision Tree

After showing the draft, intake enters a confirmation gate. The gate is mandatory — `gh issue create` is never called before it resolves.

```
Owner response
│
├── "yes" / "do it" / "create it" / "looks good" / "go ahead"
│       └── → Step 5: gh issue create (no labels)
│
├── "no" / "cancel" / "abort" / "stop"
│       └── → Stop. Confirm: "Cancelled — no issue was created."
│
├── Any edit request ("change X", "make Y shorter", "add Z")
│       └── → Revise the draft, present the full revised draft again
│           └── → Return to gate (Step 3)
│
├── Silence (no response yet)
│       └── → Do nothing. Wait.
│
└── Ambiguous ("maybe", "hang on", "not sure", "what about X?")
        └── → Ask once: "Shall I create this issue? (yes / no)"
            └── → Return to gate
```

**Never** infer consent from silence, a question, or partial confirmation. The gate resolves only when the owner types an explicit affirmative or negative.

**Edit loop limit:** there is no limit. Loop until the owner confirms or cancels.

---

## Body Schema Template

Use this template verbatim for the issue body. Fill each heading from the owner's input. When the owner's input does not supply enough detail, use the placeholder prompts shown below — they are parseable by the AFK refine stage and prompt the owner to fill them in during refine.

```markdown
**Goal**: [One non-technical sentence describing the business or user outcome.]

**Description**: [One to three sentences explaining why this matters and linking it to existing context, prior decisions, or related work. If none is known, write: "Context to be supplied during refine."]

**Requirements**:
1. [First actionable step — explicit enough for an independent developer or AI to implement. If unclear from the owner's input, write: "Requirements to be decomposed during refine."]

**Acceptance Criteria**:
- [First verifiable boundary defining when the work is done. If unclear, write: "Acceptance criteria to be defined during refine."]
```

**Rules:**
- All four headings are mandatory. Omitting any heading is a violation of C-3.
- Placeholder text is acceptable; a missing heading is not.
- Do not add additional headings (e.g. `**Notes**`, `**Background**`) — refine and plan expect exactly these four.
- Do not add labels, estimates, or priorities to the body. Those are pipeline outputs.

---

## Mobile Scoping

The intake skill's full flow (draft → confirm → `gh issue create`) requires:
- An interactive Claude Code session
- `gh` CLI tool access
- Write access to the GitHub repository

**Mobile devices** (phone, tablet) can be used for the thought-composition phase: the owner types their raw thought into a note, message, or mobile Claude session and later pastes it into a Claude Code session on a capable machine to complete the flow.

Mobile is **not** a supported execution environment for the confirmation gate or issue creation. If an owner attempts intake from a mobile context without `gh` CLI access, the correct response is:

> "I can draft the issue body here, but creating it on GitHub requires a Claude Code session with `gh` CLI access. Copy this draft and run intake in that session to create the issue."

---

## Routing Signals — Out-of-Scope Requests

When the owner's request does not belong to intake, route immediately without attempting to fulfil it:

| Request type | Route to |
|---|---|
| "Refine this issue / add more detail" | `refine` skill |
| "Break this into sub-issues / decompose" | `plan` skill |
| "Update / edit an existing issue" | `gh issue edit` directly |
| "Implement this" | `implement` skill |
| "Add a label to this issue" | Decline — labels are the pipeline's output (ADR-015) |
| "Create multiple issues at once" | Run intake once per issue in separate sessions |
| "Create the issue without showing me a draft" | Decline — confirmation gate is mandatory (C-1) |

---

## `gh issue create` Reference

Minimum correct invocation:

```bash
gh issue create \
  --title "Short action-oriented title" \
  --body "**Goal**: ...

**Description**: ...

**Requirements**:
1. ...

**Acceptance Criteria**:
- ..."
```

**Never add:**
- `--label` or `-l` — labels are the pipeline's exclusive output
- `--assignee` — the pipeline manages assignment
- `--milestone` — not used by this pipeline
- `--project` — the AFK workflow adds the issue to the board on open

The returned output is a URL (`https://github.com/<owner>/<repo>/issues/<n>`). Print it as confirmation.

---

## ADR References

| ADR | Relevance to intake |
|---|---|
| ADR-009 | Skills travel with generated projects — intake ships via Copier; it must be physically present under `.agents/skills/` in every generated project |
| ADR-011 | Issue body is the cross-runtime state carrier — intake writes the initial body; never store intake state in local files |
| ADR-015 (2026-09-23 amendment) | Labels are the pipeline's exclusive output — intake MUST NOT set any label |
