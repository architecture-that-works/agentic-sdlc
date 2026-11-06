# ADR Staging — Index

Reusable app/domain architecture decisions, staged here temporarily — see
[`README.md`](README.md) for why this isn't the final home.

| ADR | Title | Status | Applies To | Decision |
|---|---|---|---|---|
| [ADR-001](ADR-001-data-science.md) | Data Science Tooling Selection | Accepted | `project_type: ml` | Marimo (`.py`) + Pandas + scikit-learn — Git-diffable notebooks, interactive EDA, tabular ML |
| [ADR-002](ADR-002-mlops.md) | Experiment Tracking and AI Model Delivery Maturity | Accepted | `project_type: ml` | MLflow targeting Google AI Engineering Level 1 — self-hostable, tracking URI swap for Level 0→1 migration |
| [ADR-003](ADR-003-observability.md) | Observability Stack Selection | Accepted | all | OpenTelemetry + OpenLineage — no proprietary cloud SDK in instrumentation paths; exporter target via env var |
| [ADR-004](ADR-004-iam-provider-selection.md) | IAM Provider Selection | Proposed | `project_type: application`, `project_type: agent` | Keycloak (internal) or Zitadel (external/B2B) — context-dependent; FastAPI via `OAuth2AuthorizationCodeBearer` |
| [ADR-005](ADR-005-pipeline-orchestration.md) | Data Pipeline Orchestration | Proposed | `project_type: ml`, `project_type: agent` (data-intensive) | Dagster (Software-Defined Assets) when multiple production pipelines or backfill requirements emerge |
| [ADR-006](ADR-006-agent-observability.md) | Agent Observability Tooling | Accepted | `project_type: agent` | Vertex AI Service Runtime or LangSmith — context-dependent; extends ADR-003, does not replace OTel span emission |
| [ADR-008](ADR-008-secrets-management.md) | Secrets Management | Accepted | all | GitHub Secrets for dev/CI; Azure Key Vault (corporate) / GCP Secret Manager (personal) for production |
