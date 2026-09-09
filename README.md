# le-terraform

Multi-cloud infrastructure-as-code practice, one directory per cloud.

| Directory | What is in it |
|---|---|
| [`GCP/`](GCP/) | **A complete 3-tier application on GCP** — VPC, GKE, Artifact Registry, Firestore, keyless CI/CD. Fully documented, see below |
| [`Azure/`](Azure/) | Terraform for a self-managed Kubernetes cluster on Azure VMs, with OIDC-authenticated GitHub Actions |
| [`AWS/`](AWS/) | Terraform for a self-managed Kubernetes cluster on EC2 |

---

## 📘 GCP: build a 3-tier application end to end

**→ [Start the tutorial](docs/gcp-3tier-tutorial/README.md)**

A step-by-step guide that goes from an empty Google Cloud project to a
publicly reachable, three-tier application deployed by its own CI/CD pipeline,
with every piece of infrastructure defined in Terraform.

The application is **LinkForge**, a URL shortener — deliberately small, so the
infrastructure stays the focus.

```
                         Internet
                            │
             ┌──────────────▼───────────────┐
             │  Global HTTP Load Balancer   │   one public IP
             │  /      → web                │   path-based routing
             │  /api, /r → api              │
             └───┬──────────────────┬───────┘
                 │                  │
        ┌────────▼───────┐  ┌───────▼────────┐
        │ TIER 1  web    │  │ TIER 2  api    │
        │ nginx + JS     │  │ FastAPI        │
        └────────────────┘  └───────┬────────┘
           GKE cluster, private nodes │  Workload Identity, no keys
                             ┌───────▼────────┐
                             │ TIER 3         │
                             │ Firestore      │
                             └────────────────┘
```

**13 chapters, about 5 hours**, each explaining what you are doing, why that
way, what happens when you run it, and how to verify it worked.

| | | |
|---|---|---|
| [00 Overview](docs/gcp-3tier-tutorial/00-overview.md) | [01 Prerequisites](docs/gcp-3tier-tutorial/01-prerequisites.md) | [02 Bootstrap](docs/gcp-3tier-tutorial/02-bootstrap.md) |
| [03 Terraform: foundation](docs/gcp-3tier-tutorial/03-terraform-foundation.md) | [04 Terraform: cluster](docs/gcp-3tier-tutorial/04-terraform-gke.md) | [05 The application](docs/gcp-3tier-tutorial/05-application-code.md) |
| [06 Build & deploy by hand](docs/gcp-3tier-tutorial/06-manual-build-and-deploy.md) | [07 Go live](docs/gcp-3tier-tutorial/07-ingress-go-live.md) | [08 Keyless CI/CD auth](docs/gcp-3tier-tutorial/08-github-workload-identity-federation.md) |
| [09 The pipelines](docs/gcp-3tier-tutorial/09-cicd-pipelines.md) | [10 Prove it end to end](docs/gcp-3tier-tutorial/10-end-to-end-proof.md) | [11 Day 2: run it](docs/gcp-3tier-tutorial/11-day2-operations.md) |
| [12 Cost & teardown](docs/gcp-3tier-tutorial/12-cost-control-and-teardown.md) | [Glossary](docs/gcp-3tier-tutorial/98-glossary.md) | [Troubleshooting](docs/gcp-3tier-tutorial/99-troubleshooting.md) |

**Cost:** roughly **$9/month** parked, **$28/month** with the public URL live,
**under $2** for a weekend. New Google Cloud accounts get $300 in credits.
Chapter 12 covers both parking and full teardown.

### What is where

```
GCP/
├── modules/                   network · artifact-registry · firestore
│                              gke · workload-identity · github-oidc
└── linkforge/                 the root stack you run terraform in
app/
├── api/                       FastAPI microservice + 12 unit tests
└── web/                       static frontend + nginx config
k8s/                           Kubernetes manifests (+ day2/ extras)
scripts/                       env · build-and-push · deploy · loadgen
.github/workflows/
├── gcp-infra.yml              terraform plan on PR, apply/destroy on demand
└── gcp-app.yml                test → build → push → deploy → auto-rollback
```

### Notable things it demonstrates

- **No stored credentials anywhere.** Pods reach Firestore via GKE Workload
  Identity; GitHub Actions reaches GCP via Workload Identity Federation; Docker
  reaches Artifact Registry via a gcloud credential helper.
- **Private nodes with no Cloud NAT.** Private Google Access covers every API
  the workload uses, saving ~$32/month.
- **Two pipelines with two identities**, so an application deploy cannot touch
  infrastructure.
- **Zero-downtime deploys with automatic rollback** — Chapter 10 breaks
  production on purpose to prove it.

---

## Azure and AWS

Both directories build a self-managed Kubernetes cluster from VMs, driven by
`workflow_dispatch` GitHub Actions with `plan` / `apply` / `destroy` / `list`
actions. The Azure workflow authenticates with OIDC — the same idea the GCP
lab uses, in a different cloud.
