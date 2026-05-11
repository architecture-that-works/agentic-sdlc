# Security

This document describes the secrets required by this project, the rationale behind each,
and how to configure them per environment.

---

## GH_TOKEN

**Purpose:** Authenticates GitHub CLI (`gh`) calls within the Orchestrator Workflow — creating
issues, moving kanban cards, and mutating GitHub Projects v2 boards.

**Why classic PAT, not fine-grained PAT:** GitHub Projects v2 mutations (add/move/archive
project items) require the `project` OAuth scope. Fine-grained PATs do not expose this scope;
they are scoped to repository permissions only. Until GitHub extends fine-grained PATs to
cover Projects v2, a classic PAT with `repo` + `project` scopes is the only supported option.

**Accepted risk:** Classic PATs carry broader permissions than fine-grained PATs. Mitigations:
- Scope the token to `repo` and `project` only — no `admin:*`, `delete_repo`, or `write:packages`.
- Never share the token across projects; generate one per repository.
- Rotate on the schedule below.

**Rotation guidance:**
1. Open GitHub → Settings → Developer Settings → Personal access tokens → Tokens (classic).
2. Generate a new token scoped to `repo` and `project`.
3. Copy the new token value.
4. Update the secret in every environment (see table below).
5. Verify the Orchestrator Workflow completes a successful kanban-lane move.
6. Revoke the old token.

---

## ANTHROPIC_API_KEY

**Purpose:** Authenticates calls to the Anthropic Claude API made by agent skills and any
AI-backed endpoints in this project.

**Scope:** One key per project is sufficient. Do not share a key across multiple production
services — per-service keys make compromise blast-radius containment and rotation easier.

**Rotation guidance:**
1. Open console.anthropic.com → API Keys.
2. Create a new key and label it with the project name and date (e.g., `my-project-2026-05`).
3. Copy the new key value.
4. Update the secret in every environment (see table below).
5. Run `uv run pytest` against the staging environment to confirm the new key is active.
6. Delete the old key from the Anthropic console.

---

## Secrets Architecture by Environment

| Secret | Local dev (`.env`) | CI (GitHub Actions) | Production — corporate | Production — personal |
|---|---|---|---|---|
| `GH_TOKEN` | `.env` (git-ignored) | GitHub Actions Secret | Azure Key Vault | GCP Secret Manager |
| `ANTHROPIC_API_KEY` | `.env` (git-ignored) | GitHub Actions Secret | Azure Key Vault | GCP Secret Manager |
| `CLAUDE_CODE_OAUTH_TOKEN` | Not applicable — developer credential | GitHub Actions Secret | N/A — developer credential | N/A — developer credential |

**Local dev:** Copy `.env.example` to `.env` and populate values. The `.env` file is
git-ignored and must never be committed.

**CI:** Store secrets under the repository's Settings → Secrets and variables → Actions.
Reference them in workflows as `${{ secrets.SECRET_NAME }}`.

**Production — corporate:** Retrieve secrets from Azure Key Vault at runtime via the
workload-identity federation configured in the deployment pipeline. No secret value is
ever stored in the repository or environment variables of the host.

**Production — personal:** Retrieve secrets from GCP Secret Manager at runtime via the
service account attached to the Cloud Run or GCE instance. No secret value is stored
in the repository.

---

## Orchestrator Credentials

The orchestrator is a label-driven pipeline running on a self-hosted GitHub Actions runner on
the developer's machine. When an issue receives the `agent:backlog` label, the runner executes
a full PowerShell pipeline: **Refine → Develop → PR → Review loop → Squash-merge →
CONTEXT.md update**. Two secrets drive the pipeline at runtime.

### Pipeline secrets

| Secret | Role in pipeline |
|---|---|
| `GH_TOKEN` | Authenticates all `gh` CLI calls — creating/updating issues, moving kanban cards, opening PRs, and squash-merging |
| `CLAUDE_CODE_OAUTH_TOKEN` | Authenticates all `claude` CLI calls — Refine, Develop, Review, commit-message generation, and post-merge CONTEXT.md update |

### CLAUDE_CODE_OAUTH_TOKEN

**Purpose:** Authenticates every `claude -p` / `claude --print` invocation in the pipeline.
Used in all five phases:

- **Refine** — structures the issue body and assigns estimate/priority
- **Develop** — runs Claude Code non-interactively to implement requirements and verify with `uv run pytest`
- **Review** — agent self-review of the PR diff against acceptance criteria
- **Commit-message** — generates a conventional commit message from the staged diff
- **Context update** — patches `CONTEXT.md` after the PR is squash-merged

**How to obtain:**
1. Open claude.ai → click your profile → **Settings**.
2. Navigate to the **Claude Code** tab.
3. Under **OAuth Token**, click **Generate** (or **Regenerate** to rotate).
4. Copy the displayed token immediately — it is not shown again.

**Accepted risk:** The token grants full Claude Code CLI access under your Anthropic account.
Mitigations:
- Store the token exclusively as a GitHub Actions Secret — never in `.env` or committed files.
- Rotate on the schedule below.

**Rotation guidance:**
1. Open claude.ai → Settings → Claude Code → OAuth Token → **Regenerate**.
2. Copy the new token value.
3. Update the `CLAUDE_CODE_OAUTH_TOKEN` secret in GitHub: Settings → Secrets and variables → Actions.
4. Verify the next orchestrator run completes without a `claude` authentication error.
5. The old token is invalidated automatically on regeneration.

### Self-hosted runner

The `implement` job requires a self-hosted runner registered with the `gha-project` label
(see `runs-on: [self-hosted, gha-project]` in `.github/workflows/orchestrator.yml`). The
runner must have `uv`, `claude` (Claude Code CLI), `git`, and `gh` pre-installed.

- **Start:** `task runner` — starts the runner in the foreground; press Ctrl+C to interrupt.
- **Graceful stop:** `task runner OFFLINE=1` — sends a drain signal; the runner finishes any
  in-progress job before exiting.

### AFK operation checklist

One-time setup steps for a freshly generated project:

1. **Create the repository** — push the generated project to GitHub.
2. **Create a GitHub Project (v2)** — add a Status field (single-select) with at least four
   options: Backlog, Implementing, Review, Merged. Optionally add Estimate (number) and
   Priority (single-select) fields.
3. **Populate `.env`** — copy `.env.example` to `.env` and set:
   - `GH_TOKEN` — your classic PAT with `repo` and `project` scopes
   - `KANBAN_PROJECT_NUMBER` — the project number from the GitHub Project URL
   - `KANBAN_PROJECT_OWNER` — your GitHub username or organisation
4. **Add GitHub Actions Secrets** — in repository Settings → Secrets and variables → Actions,
   create:
   - `GH_TOKEN` — the same classic PAT as above
   - `CLAUDE_CODE_OAUTH_TOKEN` — obtained from claude.ai → Settings → Claude Code
5. **Run project setup** — `task setup` — queries the GitHub Project for field/option IDs
   and writes them to `.env` and as GitHub Actions repository variables.
6. **Register the self-hosted runner** — follow the setup wizard at
   `github.com/<org>/<repo>/settings/actions/runners/new`. During registration, add the
   custom label `gha-project` so the `implement` job can target this runner.
7. **Verify runner connectivity** — in GitHub → Settings → Actions → Runners, confirm the
   runner status shows **Idle**.
8. **Start the runner** — `task runner` — keep the terminal open while AFK operation is active.
9. **Sync issues** — `task sync` — pushes the local `ISSUES.md` backlog to GitHub Issues and
   applies the `agent:backlog` label to ready items.
10. **Trigger the first run** — apply the `agent:backlog` label to any open issue; the
    orchestrator picks it up and runs the full implement → review → merge pipeline.

---

## Deployment Credentials

> Extended by Phase 5.

Credentials for the deployment pipeline (container registry, Kubernetes, Terraform state
backend) will be documented here when Phase 5 components are introduced.
