# Chapter 12 — Cost Control & Teardown

⏱ ~15 minutes.

The chapter people skip, and then get a surprising bill. There are two modes
here: **park it** (keep everything, stop paying for most of it) and **destroy
it** (nothing left).

---

## Step 12.1 — Find out what you are actually paying for

**Do this.**

```bash
gcloud billing accounts list
```

Then open **[console.cloud.google.com/billing](https://console.cloud.google.com/billing)**
→ your account → **Reports**, and filter to your project. Group by **SKU** to
see individual line items.

**What you should see**, roughly per day:

| SKU | ~Per day | ~Per month |
|---|---|---|
| Network Load Balancing: Forwarding Rule | $0.60 | $18.00 |
| Spot Preemptible E2 Instance Core running | $0.15 | $4.50 |
| Spot Preemptible E2 Instance Ram running | $0.10 | $3.00 |
| Storage PD Capacity | $0.08 | $2.40 |
| Kubernetes Engine cluster management fee | $0.00 | $0.00 *(free tier)* |
| Firestore | $0.00 | $0.00 *(free tier)* |
| Artifact Registry | ~$0.00 | ~$0.05 |

> Billing data lags by **up to 24 hours**. If today looks empty, that is normal.

**Set a budget alert right now** — it takes 90 seconds and it is the single
most valuable habit in cloud work:

Console → **Billing → Budgets & alerts → Create budget**, scope it to your
project, set the amount to something like **$40**, and enable alerts at 50%,
90% and 100%. It emails you; it does not cap spending. Nothing else in cloud
gives you as much peace of mind for as little effort.

---

## Step 12.2 — Park mode: keep everything, pay almost nothing

**What we're doing.** Stopping the two things that cost real money, while
leaving your cluster, images, database and Terraform state completely intact.

Use this between sessions. Bringing it back takes about ten minutes and no
rebuilding.

### Stop the expensive things

```bash
source scripts/env.sh

# 1. Delete the load balancer (~$18/month -- the biggest single item)
kubectl delete ingress linkforge -n linkforge

# 2. Scale the node pool to zero (~$8/month in VMs and disks)
gcloud container clusters resize "$CLUSTER_NAME" \
  --node-pool primary --num-nodes 0 --zone "$ZONE" --quiet
```

**Verify.**

```bash
kubectl get nodes            # "No resources found"
kubectl get pods -n linkforge  # all Pending -- nowhere to run, which is fine
gcloud compute forwarding-rules list --global   # empty
```

**What this costs while parked:** essentially **$0/month**. The control plane
is covered by the free tier, Firestore and the state bucket are inside their
free tiers, and Artifact Registry storage is a few cents. Your cluster
configuration, your images, your data and your Terraform state all survive
untouched.

### Bring it back

```bash
gcloud container clusters resize "$CLUSTER_NAME" \
  --node-pool primary --num-nodes 2 --zone "$ZONE" --quiet

# wait ~2 minutes for nodes to be Ready
kubectl get nodes --watch

./scripts/deploy.sh
```

The Ingress comes back with a **new IP address** and takes another 5–8 minutes
to provision. Update `LINKFORGE_IP` in `scripts/env.sh` when it appears.

> To keep a stable IP across parkings, reserve a static one
> (`google_compute_global_address`) and reference it from the Ingress with the
> `kubernetes.io/ingress.global-static-ip-name` annotation. A reserved IP that
> is not attached to anything costs about $5/month, so for this lab a changing
> IP is the cheaper trade.

---

## Step 12.3 — Full teardown with Terraform

**What we're doing.** Removing everything Terraform created.

### First: delete the Kubernetes resources

**Why this order matters.** The Ingress created a Google load balancer that
Terraform does not know about — the GKE ingress controller made it, not
Terraform. If you destroy the cluster first, the controller is gone before it
can clean up, and you are left with orphaned forwarding rules, backend
services and health checks **that keep billing you**. This is the number one
way people end up paying for a lab they thought they deleted.

```bash
source scripts/env.sh

kubectl delete ingress linkforge -n linkforge

# Wait for the load balancer to actually go away -- this takes 2-3 minutes.
# Do not skip the wait.
watch -n 10 'gcloud compute forwarding-rules list --global'
```

Continue only when that list is **empty**. Then:

```bash
kubectl delete namespace linkforge
```

### Then: destroy the infrastructure

```bash
cd GCP/linkforge
terraform destroy
```

Read the plan. It should be **38 resources to destroy and nothing to add**
(19 from Chapter 03, 5 from Chapter 04, 14 from Chapter 08). Type `yes`.

**What just happened.** About 10–15 minutes. Terraform removes things in
reverse dependency order: IAM bindings, then the node pool, then the cluster,
then the registry and Firestore, then the subnet and VPC.

Expected:

```
Destroy complete! Resources: 38 destroyed.
```

**If it breaks.**

| Error | Cause | Fix |
|---|---|---|
| `Cannot destroy cluster because deletion_protection is set to true` | `deletion_protection` not `false` | Set it in the module, `terraform apply`, then destroy |
| `The network resource is already being used by ...` | An orphaned forwarding rule or a leftover load balancer | You skipped the Ingress wait. See Step 12.4 |
| `Error 400: The database is protected` | Firestore `deletion_policy` not `DELETE` | Set it, `terraform apply`, then destroy |
| Hangs on the node pool for >15 min | Pods with long termination grace periods | `kubectl delete namespace linkforge --force --grace-period=0` in another terminal |

---

## Step 12.4 — Hunt for orphans

**What we're doing.** Checking that nothing survived Terraform, because
orphaned load balancer components are silent and they bill.

**Do this.**

```bash
echo "--- forwarding rules (BILLABLE) ---";  gcloud compute forwarding-rules list --global
echo "--- target proxies ---";               gcloud compute target-http-proxies list
echo "--- url maps ---";                     gcloud compute url-maps list
echo "--- backend services ---";             gcloud compute backend-services list --global
echo "--- health checks ---";                gcloud compute health-checks list
echo "--- network endpoint groups ---";      gcloud compute network-endpoint-groups list
echo "--- disks ---";                        gcloud compute disks list
echo "--- addresses (BILLABLE if reserved) ---"; gcloud compute addresses list
echo "--- clusters ---";                     gcloud container clusters list
echo "--- networks ---";                     gcloud compute networks list
```

Every one should be empty (or, for networks, show only `default` if you never
deleted it).

**If something remains**, delete it in this order — the components depend on
each other and refuse to be removed out of sequence:

```bash
gcloud compute forwarding-rules delete NAME --global --quiet
gcloud compute target-http-proxies delete NAME --quiet
gcloud compute url-maps delete NAME --quiet
gcloud compute backend-services delete NAME --global --quiet
gcloud compute health-checks delete NAME --quiet
gcloud compute network-endpoint-groups delete NAME --zone "$ZONE" --quiet
```

---

## Step 12.5 — The nuclear option

**What we're doing.** Deleting the project itself. This is the only way to be
*completely* certain nothing is left running or billing.

**Do this** — and read the project ID out loud before you press enter:

```bash
gcloud config get-value project        # CHECK THIS FIRST
gcloud projects delete "$PROJECT_ID"
```

**What just happened.** The project is marked for deletion and enters a
**30-day recovery window**. Billing stops immediately. Within those 30 days you
can undo it:

```bash
gcloud projects undelete "$PROJECT_ID"
```

After 30 days it is irreversible, and the project ID is permanently retired —
nobody, including you, can ever reuse it.

> **This also deletes the Terraform state bucket**, so do it only when you are
> genuinely finished. If you want to keep the state (to rebuild later), copy it
> out first:
>
> ```bash
> gcloud storage cp "gs://${TF_STATE_BUCKET}/linkforge/default.tfstate" ./
> ```

---

## Step 12.6 — Final confirmation

Wait 24 hours for billing to settle, then:

```bash
gcloud projects describe "$PROJECT_ID" --format="value(lifecycleState)"
```

Expected: `DELETE_REQUESTED`, or an error saying the project does not exist.

Then check the billing report one last time. Yesterday's total should be
**$0.00**.

---

## Cost recap for the whole lab

If you worked through this in a weekend and tore it down:

| | |
|---|---|
| 2 days of cluster + nodes | ~$0.65 |
| 2 days of load balancer | ~$1.20 |
| Everything else | $0.00 (free tiers) |
| **Total** | **under $2** |

If you left it running for a month: **~$28**. If you parked it between
sessions: **~$0**.

The $300 in free-trial credits covers any of those comfortably.

---

## What you built

Starting from an empty Google Cloud project, you built and then removed:

- A custom VPC with Private Google Access and no NAT gateway
- A private-node GKE cluster on Spot VMs, inside the free-tier envelope
- A serverless Firestore data tier
- A container registry with a cleanup policy that keeps it free
- Two application tiers, load-balanced behind one IP with path-based routing
- Pod-level cloud identity with no credentials in any container
- Keyless CI/CD authentication from GitHub Actions
- Two pipelines: a reviewed, plan-first infrastructure pipeline, and a
  test-gated application pipeline that rolls itself back
- Working knowledge of logs, metrics, autoscaling, node drains and rollbacks

All of it in version control, all of it reproducible from `terraform apply`.

---

> ✅ **Checkpoint** — Nothing is running, nothing is billing, and everything
> you built is still in git — so `terraform apply` rebuilds the whole thing
> whenever you want it back.

**Back to:** [the index](README.md) · **See also:**
[Glossary](98-glossary.md) · [Troubleshooting](99-troubleshooting.md)
