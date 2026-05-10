# Security

This document describes the secrets required by this project, the rationale behind each,
and how to configure them per environment.

---

## GH_TOKEN

**Purpose:** Authenticates GitHub CLI (`gh`) calls within the Director Workflow — creating
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
5. Verify the Director Workflow completes a successful kanban-lane move.
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

> Extended by Phase 3.

Credentials for the orchestration layer (queue broker, scheduler, inter-agent tokens) will
be documented here when Phase 3 components are introduced.

---

## Deployment Credentials

> Extended by Phase 5.

Credentials for the deployment pipeline (container registry, Kubernetes, Terraform state
backend) will be documented here when Phase 5 components are introduced.
