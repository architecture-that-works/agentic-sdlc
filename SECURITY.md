# Security

Secrets this project uses and why, accepted risks, and how a human halts, overrides or rolls
back the agent pipeline. Setup steps live in the [README](README.md).

## Reporting a vulnerability

Report privately through GitHub: the repository's **Security** tab → **Report a vulnerability**
(enable *Private vulnerability reporting* under Settings → Code security). Do not open a public
issue for a suspected vulnerability.

---

## Secrets

| Secret | Used by | Local dev | CI | Production |
|---|---|---|---|---|
| `GH_TOKEN` | every `gh` call in the pipeline — issues, labels, board, PRs, merges; `task` commands locally | `.env` | Actions secret | Azure Key Vault (corporate) / GCP Secret Manager (personal) |
| `CLAUDE_CODE_OAUTH_TOKEN` | every `claude` call in the pipeline — refine, plan, implement, review, commit messages, CONTEXT.md update | your own `claude` login | Actions secret | — (developer credential) |
| `ANTHROPIC_API_KEY` | AI-backed endpoints in `src/`; `src/tools/commit.py` when the Claude CLI is absent. Not used by the pipeline | `.env` | Actions secret | Azure Key Vault / GCP Secret Manager |

`.env` is git-ignored and must never be committed. In production, secrets are read at runtime
through workload identity (Azure) or the attached service account (GCP) — no secret value is
stored in the repository or in host environment variables (ADR-008).

Give every token an expiry, rotate it before it lapses, and rotate immediately on any suspected
exposure. After rotating, update it everywhere in the table and confirm the next AFK run (or AI
call) succeeds before revoking the old value.

### GH_TOKEN — classic PAT

- **Scopes:** exactly `project`, `read:org`, `repo`, `user`, `workflow` — `project` for board
  mutations, `repo` for issues/PRs/commits, `workflow` for PRs that touch
  `.github/workflows/`, `read:org` for org-owned boards, `user` for identity calls. Never
  `admin:*`, `delete_repo` or `write:packages`.
- **Why classic:** fine-grained PATs cannot mutate Projects v2 boards. **Why a PAT at all:**
  label changes made with the workflow's built-in `GITHUB_TOKEN` do not trigger workflows, and
  the `ship` job is triggered by the `agent:reviewing` label.
- **Accepted risk:** a classic PAT is broader than a fine-grained one. Generate one per
  repository and never share it across projects.
- **Accepted risk (ADR-012):** the cloud pipeline and your local `gh` authenticate as the same
  user and share one GraphQL budget (5000 points/hour). A separate bot account would isolate it
  but is deferred; the pipeline's GraphQL use was cut instead.
- **Create/rotate:** GitHub → Settings → Developer settings → Personal access tokens → Tokens
  (classic).

### CLAUDE_CODE_OAUTH_TOKEN

- **Create/rotate:** run `claude setup-token` (requires a Claude subscription) and copy the
  long-lived token it prints — it is shown once.
- **Accepted risk:** it grants full Claude Code access under your account. Store it only as an
  Actions secret — never in `.env` or a committed file.

### ANTHROPIC_API_KEY

- **Create/rotate:** console.anthropic.com → API Keys; label it with the project and date.
- Use one key per service so a compromise can be contained and rotated in isolation.

---

## Human Oversight

Every agent action can be halted, overridden or rolled back by a human. All mechanisms below
are manual; the pipeline never escalates, retries or rolls back on its own beyond its bounded
review loop (`KANBAN_MAX_RETRIES` implement → review cycles, then `agent:failed`). Each
browser step also works from the GitHub mobile web UI.

### Halt

| To stop… | Do this |
|---|---|
| Everything, immediately | Actions → AFK → **⋯ → Disable workflow** (`gh workflow disable afk.yml`). No stage runs, including refine on new issues, until re-enabled. |
| The current run | Actions → the running AFK run → **Cancel workflow** (`gh run cancel <run-id>`). The feature branch and any open PR are kept. |
| An issue from being processed | Close it; reopen it to release it. The pipeline only processes open issues — removing `agent:backlog` is not enough, because the next `stage=all` run re-aligns any open issue without an `agent:*` label. |
| An issue from auto-merging | Add `human:approval`, at any point before ship. The pipeline implements and self-reviews, then holds at `agent:reviewing` and comments on the issue; only a human merges the PR. |

A cancelled run can leave the issue on `agent:implementing` or `agent:reviewing`. Resume it
with `task retry ISSUE=<n>`: it re-dispatches refine or ship when that stage failed, and
otherwise re-queues the issue to `agent:backlog` for the next `task afk`.

### Override

- **Answer a question.** Comment on the `human:decision` issue and close it; closing without a
  comment accepts the agent's recommendation. Refine records the answer in the parent's
  `decided_questions[]` and re-refines the parent when its last question closes.
- **Correct a refine decision.** The issue body is the pipeline's only state (ADR-011) and the
  implement stage reads it verbatim. Edit the **Agent Brief** section, or a
  `decided_questions[]` entry in the `AGENT-STATE` block, then re-run refine
  (`task refine ISSUE=<n>`, or Run workflow with `stage=refine`). Architecture Impact and Implementation Plan are regenerated on every refine
  run, so edit them once the issue has `agent:backlog`; from then on edits take effect at the
  next implement without a re-run.
- **Run a specific stage.** Actions → AFK → **Run workflow** with `stage` and `issue_number`:
  - `all` (default) — refine every un-aligned issue, then drain `agent:backlog`.
  - `refine` — re-align one issue; `0` aligns every un-aligned issue.
  - `implement` — process that issue if it carries `agent:backlog`, otherwise the oldest
    `agent:backlog` issue; `0` drains the queue.
  - `ship` — merge the issue's PR. Requires an approval signal (`agent:reviewing` or an
    approved PR review) and still honours the `human:approval` hold.
  Locally, `task hitl ISSUE=<n>` runs implement → review → ship in your terminal.
- **Reject the agent's work.** Close the PR without merging. To have the agent try again, put
  your feedback in the issue body (e.g. the Agent Brief) and run `task retry ISSUE=<n>`. The
  agent reads the issue body and its 🤖 signal comments — not PR review comments.

### Roll back

Ship squash-merges one commit per issue, then may push a follow-up `chore(context)` commit that
updates CONTEXT.md directly on the default branch.

1. On the merged PR, click **Revert** and merge the revert PR (or `git revert <squash-sha>`
   through a PR). Revert the follow-up CONTEXT.md commit too, if there is one — `git log -3
   -- CONTEXT.md` on the default branch shows it.
2. Reopen the issue (`gh issue reopen <n>`) and remove `agent:shipped`.
3. To redo it, run `task retry ISSUE=<n>` then `task afk` — the refine/architect/plan state in
   the issue body is kept, so it re-enters `agent:backlog` directly. Otherwise close it as not
   planned.

---

## Deployment Credentials

The `deploy.yml` workflow deploys the container image built by `build.yml` to either
Azure Container Apps or GCP Cloud Run. The target cloud is selected by the repository
variable `DEPLOY_TARGET` (`azure` or `gcp`), set once at project setup. Both jobs
authenticate via **Workload Identity Federation (WIF)** — no service principal secret
or service account JSON key is ever stored in the repository.

### Required secrets and variables

| Cloud | Repository variables | Repository secrets |
|---|---|---|
| Azure | `DEPLOY_TARGET=azure`, `AZURE_CONTAINER_APP_NAME`, `AZURE_RESOURCE_GROUP` | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| GCP   | `DEPLOY_TARGET=gcp`, `GCP_CLOUD_RUN_SERVICE`, `GCP_REGION` | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` |

Variables live under **Settings → Secrets and variables → Actions → Variables**.
Secrets live under **Settings → Secrets and variables → Actions → Secrets**.

### Provisioning WIF for Azure

> **Manual intervention — human action required.** This procedure cannot run from inside CI; it
> requires Owner or User Access Administrator on the target subscription. Perform
> it once, manually, after `deploy.yml` lands on `main`. The repository secrets
> and variables produced in steps 4–5 are what `deploy.yml` consumes at runtime.

1. **Create an Entra ID app registration**
   ```bash
   az ad app create --display-name "github-actions-<repo>"
   APP_ID=$(az ad app list --display-name "github-actions-<repo>" --query "[0].appId" -o tsv)
   az ad sp create --id "$APP_ID"
   ```
2. **Grant the service principal contributor on the resource group**
   ```bash
   SUB_ID=$(az account show --query id -o tsv)
   az role assignment create \
     --assignee "$APP_ID" \
     --role contributor \
     --scope "/subscriptions/$SUB_ID/resourceGroups/<AZURE_RESOURCE_GROUP>"
   ```
3. **Add a federated credential trusting this GitHub repository** (one per environment
   you intend to deploy to — repeat for `staging` and `production`):
   ```bash
   az ad app federated-credential create --id "$APP_ID" --parameters '{
     "name": "github-<repo>-staging",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:<owner>/<repo>:environment:staging",
     "audiences": ["api://AzureADTokenExchange"]
   }'
   ```
4. **Record the three identifiers as GitHub Actions secrets**:
   - `AZURE_CLIENT_ID` — `$APP_ID`
   - `AZURE_TENANT_ID` — `az account show --query tenantId -o tsv`
   - `AZURE_SUBSCRIPTION_ID` — `$SUB_ID`
5. **Record the deployment targets as repository variables**:
   - `DEPLOY_TARGET=azure`
   - `AZURE_CONTAINER_APP_NAME` — the Container App name
   - `AZURE_RESOURCE_GROUP` — the resource group containing the Container App
6. **Allow the Container App to pull the GHCR image** — either make the GHCR package
   public, or configure registry credentials on the Container App (`az containerapp
   registry set --server ghcr.io --username <user> --password <PAT>`). A PAT with
   `read:packages` scope is sufficient.

### Provisioning WIF for GCP

> **Manual intervention — human action required.** This procedure cannot run from inside CI; it
> requires `roles/iam.workloadIdentityPoolAdmin` and `roles/iam.serviceAccountAdmin`
> on the target project. Perform it once, manually, after `deploy.yml` lands on
> `main`. The repository secrets and variables produced in steps 4–5 are what
> `deploy.yml` consumes at runtime.

1. **Create a workload identity pool and OIDC provider for GitHub**
   ```bash
   PROJECT_ID=<gcp-project-id>
   gcloud iam workload-identity-pools create "github-pool" \
     --project="$PROJECT_ID" --location="global" \
     --display-name="GitHub Actions Pool"
   gcloud iam workload-identity-pools providers create-oidc "github-provider" \
     --project="$PROJECT_ID" --location="global" \
     --workload-identity-pool="github-pool" \
     --display-name="GitHub OIDC" \
     --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
     --issuer-uri="https://token.actions.githubusercontent.com" \
     --attribute-condition="assertion.repository=='<owner>/<repo>'"
   ```
2. **Create a service account for the deploy workflow and grant Cloud Run deploy roles**
   ```bash
   gcloud iam service-accounts create github-deploy \
     --project="$PROJECT_ID" --display-name="GitHub Actions Deploy"
   SA_EMAIL="github-deploy@$PROJECT_ID.iam.gserviceaccount.com"
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="serviceAccount:$SA_EMAIL" --role="roles/run.admin"
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="serviceAccount:$SA_EMAIL" --role="roles/iam.serviceAccountUser"
   ```
3. **Bind the GitHub repository to the service account**
   ```bash
   PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
   gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
     --project="$PROJECT_ID" \
     --role="roles/iam.workloadIdentityUser" \
     --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/attribute.repository/<owner>/<repo>"
   ```
4. **Record the WIF provider resource name and service account email as secrets**:
   - `GCP_WORKLOAD_IDENTITY_PROVIDER` — `projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider`
   - `GCP_SERVICE_ACCOUNT` — `$SA_EMAIL`
5. **Record the deployment targets as repository variables**:
   - `DEPLOY_TARGET=gcp`
   - `GCP_CLOUD_RUN_SERVICE` — the Cloud Run service name
   - `GCP_REGION` — the region the service runs in (e.g., `europe-west1`)
6. **Allow Cloud Run to pull the GHCR image** — either make the GHCR package public,
   or mirror the image to Artifact Registry. Cloud Run does not support pulling from a
   private GHCR registry with credentials at runtime; mirroring is the supported path.

### Running the GHCR image locally for manual testing

Pull and run the same image the pipeline will deploy. Useful for reproducing a
production issue or smoke-testing before triggering `deploy.yml`.

1. **Authenticate Docker to GHCR** (only required while the package is private):
   ```bash
   echo "$GH_TOKEN" | docker login ghcr.io -u <github-username> --password-stdin
   ```
   The `GH_TOKEN` PAT needs `read:packages` scope.
2. **Pull the image** — use a pinned SHA tag for reproducibility, or `latest` for the
   most recent build on `main`:
   ```bash
   docker pull ghcr.io/<owner>/<repo>:<image_tag>
   ```
3. **Run the container**:
   ```bash
   docker run --rm -it \
     --env-file .env \
     -p 8000:8000 \
     ghcr.io/<owner>/<repo>:<image_tag>
   ```
   Adjust the published port to match whatever the application binds to. `--env-file`
   wires the same secrets used in local dev — never bake secret values into a `docker
   run` command line, as they leak into shell history and process listings.
