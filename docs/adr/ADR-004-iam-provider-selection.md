# ADR-004: IAM Provider Selection (Keycloak vs Zitadel)

## Status
Proposed

## Context and Problem Statement
When a managed SaaS provider (Azure AD, Auth0) is ruled out by data residency, cost, or open-source requirements, a self-hosted IAM provider is needed. The two primary candidates are Keycloak and Zitadel.

## Considered Options
- Keycloak
- Zitadel

## Decision Outcome
Chosen: Context-dependent — see decision drivers below.

## Pros and Cons of the Options

### Keycloak
- Good, because: enterprise/on-premise/LDAP+AD integration, 10+ years ecosystem, SAML + Kerberos + legacy AD support
- Good, because: gold standard for corporate identity (internal employee SSO, private network)
- Bad, because: Java runtime — higher memory footprint, slower startup
- Bad, because: multi-tenancy via Realms — management overhead at scale

### Zitadel
- Good, because: Go runtime — low memory, instant startup, Kubernetes-friendly
- Good, because: native multi-tenancy for B2B SaaS (thousands of tenant organisations)
- Good, because: event-sourced audit log — immutable history of every change
- Bad, because: smaller ecosystem (but growing fast)
- Bad, because: OAuth2/OIDC/SAML only — no LDAP/Kerberos/legacy AD

## Decision Drivers

| Criterion | Keycloak | Zitadel |
|---|---|---|
| Runtime | Java — higher memory, slower start | Go — low memory, instant startup |
| Multi-tenancy | Realms — management overhead | Native organisations — designed for scale |
| Protocol support | OAuth2, OIDC, SAML, LDAP, Kerberos, AD | OAuth2, OIDC, SAML |
| Customisation | Java SPIs | JavaScript Actions + API-first |
| Audit / compliance | Standard logs | Event sourcing — immutable history |
| Best for | Internal employees, corporate SSO, private network | External customers, B2B SaaS, multi-tenant |

**Choose Keycloak when:** managing internal employees on a private network with LDAP/AD integration.
**Choose Zitadel when:** managing external customers or B2B tenants where each needs their own SSO and branding.

Both integrate identically with FastAPI via `OAuth2AuthorizationCodeBearer`. IAM server deployment follows `harness` environment standards.
