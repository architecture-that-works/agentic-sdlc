---
name: intake-examples
description: End-to-end example sequences for the intake skill
---

# Intake — Examples

## Example 1 — Single-sentence thought to created issue

This is the tracer-bullet sequence: one sentence of raw thought becomes a well-formed issue.

---

**Owner input:**

> Add dark mode support to the dashboard

---

**Agent draft (Step 2 → Step 3):**

```
Here is the draft issue:

**Title:** Add dark mode support to the dashboard

---

**Goal**: Allow users to switch the dashboard to a dark colour scheme to reduce eye strain in low-light environments.

**Description**: The dashboard currently renders only in a light theme. Users working in low-light environments have requested a dark mode toggle. This feature adds the visual preference without changing any underlying data or logic.

**Requirements**:
1. Add a dark/light mode toggle control to the dashboard header.
2. Persist the user's preference in localStorage so it survives page refresh.
3. Apply a CSS class (e.g. `data-theme="dark"`) to the root element when dark mode is active.
4. Requirements to be decomposed during refine.

**Acceptance Criteria**:
- [ ] Toggling the control switches the dashboard to dark mode within one render cycle.
- [ ] Refreshing the page restores the user's last-selected theme.
- [ ] No regression in the light-mode layout.
- [ ] Acceptance criteria to be defined during refine.

---

Shall I create this issue? (yes / no)
```

---

**Owner response:**

> yes

---

**Agent action (Step 5):**

```bash
gh issue create \
  --title "Add dark mode support to the dashboard" \
  --body "**Goal**: Allow users to switch the dashboard to a dark colour scheme to reduce eye strain in low-light environments.

**Description**: The dashboard currently renders only in a light theme. Users working in low-light environments have requested a dark mode toggle. This feature adds the visual preference without changing any underlying data or logic.

**Requirements**:
1. Add a dark/light mode toggle control to the dashboard header.
2. Persist the user's preference in localStorage so it survives page refresh.
3. Apply a CSS class (e.g. \`data-theme=\"dark\"\`) to the root element when dark mode is active.
4. Requirements to be decomposed during refine.

**Acceptance Criteria**:
- [ ] Toggling the control switches the dashboard to dark mode within one render cycle.
- [ ] Refreshing the page restores the user's last-selected theme.
- [ ] No regression in the light-mode layout.
- [ ] Acceptance criteria to be defined during refine."
```

---

**Agent confirmation:**

```
Issue created: https://github.com/<owner>/<repo>/issues/301
```

---

## Example 2 — Owner requests an edit before confirming

Demonstrates the edit loop in the confirmation gate.

---

**Owner input:**

> we need a way to export reports as PDF

---

**Agent draft (Step 2 → Step 3):**

```
Here is the draft issue:

**Title:** Add PDF export for reports

---

**Goal**: Enable users to download any report as a PDF file for offline sharing and printing.

**Description**: Reports are currently only viewable in-browser. Stakeholders need to share snapshots offline. A PDF export button on each report page addresses this without requiring a backend change.

**Requirements**:
1. Add an "Export as PDF" button to each report page.
2. Requirements to be decomposed during refine.

**Acceptance Criteria**:
- [ ] Clicking the button downloads a PDF matching the visible report layout.
- [ ] Acceptance criteria to be defined during refine.

---

Shall I create this issue? (yes / no)
```

---

**Owner response:**

> Change the title to "Export reports to PDF" and add a requirement that the filename includes the report name and date

---

**Agent revised draft (edit loop → Step 3):**

```
Here is the revised draft:

**Title:** Export reports to PDF

---

**Goal**: Enable users to download any report as a PDF file for offline sharing and printing.

**Description**: Reports are currently only viewable in-browser. Stakeholders need to share snapshots offline. A PDF export button on each report page addresses this without requiring a backend change.

**Requirements**:
1. Add an "Export as PDF" button to each report page.
2. The downloaded filename must follow the format `<report-name>-<YYYY-MM-DD>.pdf`.
3. Requirements to be decomposed during refine.

**Acceptance Criteria**:
- [ ] Clicking the button downloads a PDF matching the visible report layout.
- [ ] The filename matches the `<report-name>-<YYYY-MM-DD>.pdf` pattern.
- [ ] Acceptance criteria to be defined during refine.

---

Shall I create this issue? (yes / no)
```

---

**Owner response:**

> looks good

---

**Agent action (Step 5):**

Calls `gh issue create` with the revised title and body. No `--label` flags. Prints the returned URL.

---

## Example 3 — Owner cancels

Demonstrates the abort path.

---

**Owner input:**

> maybe add a notifications panel

---

**Agent draft (Step 2 → Step 3):** *(draft shown as above)*

---

**Owner response:**

> actually no, not yet

---

**Agent response:**

```
Cancelled — no issue was created.
```

No `gh issue create` call is made.
