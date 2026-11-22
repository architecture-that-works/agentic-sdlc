<!--
What GitHub enforces on a pull request here (.github/tasks/protect.ps1):
- Required checks: lint, typecheck, test, audit, checks and eval (eval reports success when no model-facing path changed).
- Squash merging only. The pull request's title becomes the commit's title and the commits' messages become its body,
  so write the title as `<type>(#<issue>): <subject>`.
The orchestrator fills these sections itself. Keep the section headings: a heading it does not know stops it.
-->

## Summary
<!-- What this pull request changes, and why. -->

## Left undone
<!-- What was skipped or not checked, or `none`. -->

## Issues discovered
<!-- What the owner must know: a risk, a bug outside scope, a stale document, a setting to change. Or `none`. -->

## Validation
<!-- The commands run and their results, one per line, e.g. `uv run pytest` → 0. -->

Closes #
