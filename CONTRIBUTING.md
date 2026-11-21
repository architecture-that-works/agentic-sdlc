# Contributing

How an idea becomes a merged pull request in this repository.

## Propose a change

Open an issue with the template: **Issues → New issue**. Fill in the four headings (Goal,
Description, Requirements, Acceptance Criteria). Do not set labels; the workflow sets them.

## What happens next

- The workflow may ask questions in the issue. Answer them there, in a comment.
- The workflow then opens the pull request and runs the checks.
- Some pull requests are held for approval (label `human:approval`). The owner merges those.

## Whose issues the workflow acts on

Only issues from authors whose association with this repository is owner, member or
collaborator. Issues from anyone else are not acted on.

## A pull request made by hand

- All checks must pass: tests, lint, format and the `check-*` validators.
- A pull request from a fork needs approval before the workflows run.
- Commit messages follow `<type>(#<issue>): <subject>`.

## Reporting a vulnerability

Do not open a public issue. Report it privately as described in
[SECURITY.md](SECURITY.md#reporting-a-vulnerability).
