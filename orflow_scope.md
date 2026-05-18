# OrFlow API — Capstone Scope Document
**Track A: Infrastructure-First**
**Date:** May 2026

---

## 1. Problem Statement

OrFlow API currently has no isolated staging environment, environment-specific
configuration management, or monitoring layer. This means that every deployment
goes directly to production with unvalidated configuration and no visibility into
failures — creating real risk of data corruption or undetected outages.

---

## 2. In-Scope Components

**OrFlow API** — A lightweight containerized REST API (`POST /orders`,
`GET /orders`, `GET /health`) written in Python/Flask, deployed on Kubernetes.

**Terraform** — Provisions two Kubernetes namespaces: `orflow-staging` and
`orflow-production`, isolated from each other.

**Ansible** — Configures both namespaces post-provisioning with the correct
environment context and labels.

**Kubernetes Deployment** — Runs OrFlow API in both namespaces with liveness
and readiness probes and an Ingress resource.

**ConfigMaps** — Carries environment-specific values (`DB_HOST`, `ENV`) for
staging and production separately, using the same Deployment manifest for both.

**Jenkins Pipeline** — Deploys to staging automatically on every merge to main,
runs a smoke test against `GET /health`, and only opens the production approval
gate after the smoke test passes.

**Monitoring Signal** — A log-based error rate calculation reading from OrFlow
API structured logs and writing a summary to a monitoring file, following the
Week 7 SLO pattern.

**Serverless Receipt Chain** — Three functions (`kk-receiver`, `kk-processor`,
`kk-notifier`) triggered when `POST /orders` succeeds in staging, writing a
receipt event to an output bucket.

---

## 3. Out of Scope

- A fourth serverless analytics function (`kk-analytics`) — Track B requirement.
- Real cloud deployment (AWS, GCP, Cloudflare) — pipeline and Kubernetes run on
  a local or provisioned cluster; no cloud provider account is required.
- A frontend or user interface — OrFlow API is a backend service only.
- Database provisioning — ConfigMaps carry `DB_HOST` but no database instance
  is set up as part of this project.
- Authentication or authorization — no API keys, JWT, or RBAC on any endpoint.
- Load testing or performance benchmarking — the smoke test validates health
  only, not throughput or latency.
- Multi-cloud or disaster recovery configuration.

---

## 4. Success Criteria

1. `kubectl rollout status deployment/orflow-api -n orflow-staging` returns
   exit 0 after every merge to main.

2. The Jenkins smoke test hits `GET /health` on the staging deployment and
   receives HTTP 200 before the production approval gate is presented.

3. `kubectl get configmap -n orflow-staging` and
   `kubectl get configmap -n orflow-production` show different `DB_HOST`
   values, confirming environment isolation.

4. A `POST /orders` to the staging endpoint triggers the serverless receipt
   chain and a receipt event appears in the output bucket.

5. The monitoring file contains a structured log summary showing the error rate
   calculated from OrFlow API logs after a simulated failure.

---

## 5. Architecture

> See `architecture.png` — the diagram shows all components and data/event flows
> across the Git → Jenkins → Kubernetes (staging and production) →
> Serverless Receipt Chain path.

**Data flow summary:**

```
Git (merge to main)
  └─► Jenkins Pipeline
        ├─► orflow-staging namespace
        │     ├── OrFlow API pod (ConfigMap: DB_HOST=staging-db)
        │     ├── Smoke test: GET /health → 200
        │     └── POST /orders → kk-receiver → kk-processor → kk-notifier
        │                                                         └─► Output bucket
        │
        ├─► [Approval gate]
        │
        └─► orflow-production namespace
              ├── OrFlow API pod (ConfigMap: DB_HOST=prod-db)
              └── Monitoring signal → monitoring.log (error rate summary)
```

---

*Scope document v1.0 — OrFlow API Capstone, Track A*