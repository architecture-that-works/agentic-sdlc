---
name: ADR-010-runner-profile-variable
description: Decision to introduce KANBAN_RUNNER_PROFILE variable switching the orchestrator default from self-hosted to GHA-hosted ubuntu-latest — records the subscription-billing vs free-self-hosted trade-off and the variable contract
applies_to: all
---

# ADR-010: Runner Profile Variable for AFK Orchestration Lane

## Status

Proposed

## Context and Problem Statement

The AFK orchestration workflow (`orchestrator.yml`) previously hardcoded `runs-on: [self-hosted, gha-project]`, tying every autonomous implementation run to the developer's laptop. This created two adoption barriers:

1. **Forkers must stand up a self-hosted runner** before any AFK issue can execute — a multi-step prerequisite that blocks the "5-minute setup" adoption story.
2. **The laptop must remain online** for the duration of every orchestration run (implement → review → merge), which can take 20–60 minutes for typical issues.

GitHub-hosted `ubuntu-latest` runners eliminate both barriers: they start on demand, are maintained by GitHub, and support subscription-billed Claude via `CLAUDE_CODE_OAUTH_TOKEN` (minted by `claude setup-token`). The only cost is that each run debits the user's Claude Max subscription token budget rather than consuming local compute.

The decision is to introduce a repository variable `KANBAN_RUNNER_PROFILE` that switches the implement job between `ubuntu-latest` (hosted, default) and the `[self-hosted, gha-project]` labels (self-hosted, opt-in).

## Considered Options

* **Option A — GHA-hosted ubuntu-latest as default (KANBAN_RUNNER_PROFILE=hosted)**
* **Option B — Self-hosted as permanent default with no variable**
* **Option C — Separate workflow files (orchestrator-hosted.yml / orchestrator-selfhosted.yml)**

## Decision Outcome

Chosen option: **Option A**, because it unlocks the "anyone with a Max sub adopts this in 5 minutes" adoption funnel (the Phase-1 tracer bullet) while keeping the self-hosted path one variable change away for cost-sensitive users.

### Variable contract

| Variable | Type | Allowed values | Default set by `task setup` |
|----------|------|---------------|------------------------------|
| `KANBAN_RUNNER_PROFILE` | Repository variable | `hosted`, `self-hosted` | `hosted` |

Expression used in `orchestrator.yml`:

```yaml
runs-on: ${{ vars.KANBAN_RUNNER_PROFILE == 'self-hosted' && fromJSON('["self-hosted","gha-project"]') || 'ubuntu-latest' }}
```

When the variable is absent (not yet set), the expression evaluates to `ubuntu-latest` — safe for forked repos that run `task setup` only once.

### Hosted runner tooling

On `ubuntu-latest`, `pwsh`, `git`, and `gh` are pre-installed. The workflow adds an `Install tooling (hosted runner)` step that executes only when `KANBAN_RUNNER_PROFILE != 'self-hosted'` and installs:

- `uv` via the official installer (`astral.sh/uv/install.sh`)
- `@anthropic-ai/claude-code` via `npm install -g`
- A bot git identity (`github-actions[bot]`)

### Action-output audit note

Requirements for this ADR include auditing `anthropics/claude-code-base-action` output format (text-only vs. tool-call stream) when invoked from a GHA-hosted runner. The kanban scripts currently invoke the Claude CLI directly via `Invoke-ClaudeStreaming` and parse `--output-format stream-json`. If a follow-up issue determines that the base action is preferable on hosted runners, a translation layer will be needed to map action outputs into the existing `🤖`-prefixed signal-comment cadence. That work is scoped as a follow-up and does not block this ADR.

### Confirmation

* `KANBAN_RUNNER_PROFILE` is set to `hosted` after a fresh `task setup` run — verify with `gh variable list`.
* A probe issue labeled `agent:backlog` triggers `orchestrator.yml` and the implement job runs on `ubuntu-latest` (visible in the workflow run's runner column).
* Setting `gh variable set KANBAN_RUNNER_PROFILE --body 'self-hosted'` and re-triggering causes the implement job to claim a `[self-hosted, gha-project]` runner.
* The post-merge CONTEXT.md update step retains its `CLAUDE_CODE_OAUTH_TOKEN` skip-silent guard — Copier-generated forks without the token do not fail loudly.
* Revisit if GitHub changes ubuntu-latest tool availability or if Claude Max billing model changes.

## Pros and Cons of the Options

### Option A — GHA-hosted ubuntu-latest as default

| | |
|---|---|
| **Good** | Zero local prerequisites — any forker with a Max sub can adopt in 5 minutes |
| **Good** | No laptop uptime requirement — runs complete asynchronously |
| **Good** | Self-hosted path preserved via one variable change |
| **Bad** | Each orchestration run debits the Claude Max subscription token budget |
| **Bad** | Tool install steps add ~30–60 s cold-start overhead per run |

### Option B — Self-hosted as permanent default

| | |
|---|---|
| **Good** | No subscription billing per run |
| **Good** | Full control over runtime environment |
| **Bad** | Blocks adoption — forkers must stand up a runner before any AFK issue runs |
| **Bad** | Requires laptop to remain online for every run |

### Option C — Separate workflow files

| | |
|---|---|
| **Good** | No expression complexity in `runs-on` |
| **Bad** | Two files to maintain — divergence risk |
| **Bad** | Forkers must know to activate the hosted variant manually |
