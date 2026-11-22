# Contributing

How an idea becomes a merged pull request in this repository.

## Propose a change

Open an issue with the template (**Issues → New issue**, `.github/ISSUE_TEMPLATE/issue.md`).
Do not set labels; the workflow sets them.

## What happens next

- The workflow may ask questions in the issue. Answer them there, in a comment.
- The workflow then opens the pull request and runs the checks.
- A draft pull request is the workflow's work in progress. Do not merge it: GitHub refuses
  to, and the workflow may still change it.
- A pull request marked ready for review is the one to merge. The workflow marks it ready
  when it holds it for the owner, or right before it merges it itself.
- Some pull requests are held for approval (label `human:approval`). The owner merges those.

## Whose issues the workflow acts on

Only issues from authors who are owner, member or collaborator of this repository. Issues from
anyone else are not acted on.

## A pull request made by hand

- The description follows the pull request template, `.github/PULL_REQUEST_TEMPLATE.md`: write
  under each heading what its comment asks, ending with `Closes #<issue>` when there is an
  issue.
- All checks must pass: tests, lint, format and the `check-*` validators. A pull request from
  a fork needs approval before the workflows run.
- The title becomes the commit on the default branch: `<type>(#<issue>): <subject>`, or
  `<type>: <subject>` when there is no issue.
- A branch `feature/<number>-…` belongs to that issue; the workflow acts on it when the pull
  request closes. Without an issue, use another branch name.

## Reporting a vulnerability

Do not open a public issue. Report it privately as described in
[SECURITY.md](SECURITY.md#reporting-a-vulnerability).
