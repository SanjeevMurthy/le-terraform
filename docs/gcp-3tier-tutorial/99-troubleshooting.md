# Troubleshooting Index

Organised by **what you are seeing**, because that is what you know when
something goes wrong.

---

## Before anything else: the four-command sanity check

Nine times out of ten one of these is the answer.

```bash
source scripts/env.sh                      # 1. Are the variables loaded?
echo "$PROJECT_ID"                         #    ...and not "REPLACE-ME"?
gcloud config get-value project            # 2. Right default project?
kubectl config current-context             # 3. Right cluster?
gcloud auth list                           # 4. Right identity, marked ACTIVE?
```

A surprising share of "Terraform is broken" turns out to be a terminal where
`scripts/env.sh` was never sourced.

---

## Setup and authentication

### `could not find default credentials`
Terraform or the Python client cannot find ADC. There are **two** kinds of
gcloud login and you probably only did one:

```bash
gcloud auth application-default login
```

### `gke-gcloud-auth-plugin was not found`
`kubectl` cannot authenticate to GKE without it.

```bash
gcloud components install gke-gcloud-auth-plugin
# or, if gcloud came from a package manager:
sudo apt-get install google-cloud-cli-gke-gcloud-auth-plugin
```

Then re-run `gcloud container clusters get-credentials ...`.

### `PERMISSION_DENIED` / `BILLING_DISABLED`
```bash
gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)"
```
If `False`, link a billing account (Chapter 02, Step 2.2).

### `Requested entity already exists` creating the project
Project IDs are globally unique across all of Google Cloud. Pick another,
update `scripts/env.sh`, `source` it again.

---

## Terraform

### `Error acquiring the state lock`
A previous run died holding the lock. Confirm nothing else is running, then
use the `ID` from the error message:

```bash
terraform force-unlock LOCK_ID
```

### `storage: bucket doesn't exist`
`TF_STATE_BUCKET` is empty or wrong when you ran `init`.

```bash
echo "$TF_STATE_BUCKET"
gcloud storage ls | grep tf-state
```

Fix `scripts/env.sh`, `source` it, and re-run `terraform init` with the
`-backend-config` flags.

### `API has not been used in project ... or it is disabled`
An API enablement had not propagated when a resource tried to use it. **Just
run `terraform apply` again** — it is idempotent and almost always succeeds on
the second pass.

### `Reference to undeclared module`
You are on Chapter 03 and `main.tf` references `module.github_oidc`, which does
not exist until Chapter 08. Set `writer_members = []` for now (Chapter 03,
Step 3.6).

### `Cannot destroy cluster because deletion_protection is set to true`
Confirm `deletion_protection = false` in `GCP/modules/gke/main.tf`, run
`terraform apply` to push that change, *then* destroy.

### `Error 409: Database already exists` (Firestore)
The project already has a `(default)` database. Import it rather than
recreating:

```bash
terraform import 'module.firestore.google_firestore_database.default' \
  "projects/${PROJECT_ID}/databases/(default)"
```

### The plan wants to destroy and recreate something unexpected
Stop. Read which attribute triggered it — the plan marks it
`# forces replacement`. Common culprits: changing a Firestore `location_id`,
a subnet's secondary ranges, or a cluster's network. All of those are
genuinely immutable, and the plan is telling you the truth.

---

## Cluster and nodes

### Nodes stuck `NotReady`
```bash
kubectl describe node NODE_NAME | tail -30
```
Usually the node service account is missing `roles/logging.logWriter` or
`roles/monitoring.metricWriter`.

### `Unable to connect to the server: dial tcp ... i/o timeout`
`master_authorized_cidrs` does not include your current IP.

```bash
curl -s ifconfig.me     # your IP
```
Add it, or set the list back to `[]`, and `terraform apply`.

### `Insufficient regional quota to satisfy request: resource "CPUS"`
New projects get low quotas. Either request an increase (Console → IAM & Admin
→ Quotas) or drop `node_count` to `1` in `terraform.tfvars`.

### A node vanished on its own
You are running Spot nodes. Google reclaimed it. A replacement appears
automatically; your Pods reschedule. This is expected, and Chapter 11,
Exercise 4 is exactly this scenario on purpose.

---

## Pods

### `ImagePullBackOff`
```bash
kubectl describe pod -n linkforge POD_NAME | grep -A5 Events
```

| Message contains | Cause |
|---|---|
| `not found` / `manifest unknown` | Wrong tag. Check `gcloud artifacts docker images list "$IMAGE_REPO" --include-tags` |
| `denied` / `unauthorized` | The node service account lacks `roles/artifactregistry.reader` on the repository |
| a **Docker Hub** image name | **Expected.** Your nodes have no public internet route. Push the image to Artifact Registry, or set `enable_cloud_nat = true` temporarily |

### `CrashLoopBackOff`
The real error is in the **previous** container, not the current one:

```bash
kubectl logs -n linkforge POD_NAME --previous
```

### `Running` but stuck at `0/1`
The readiness probe is failing. Check the port and path match reality:

```bash
kubectl describe pod -n linkforge POD_NAME | grep -A3 Readiness
kubectl exec -n linkforge POD_NAME -- wget -qO- http://localhost:8080/readyz
```

### `Pending` forever
```bash
kubectl describe pod -n linkforge POD_NAME | grep -A5 Events
```
`Insufficient cpu` / `Insufficient memory` means no node has room. Either your
requests are too big or you need more nodes. If you applied the HPA, check you
also deleted the `replicas:` line from the Deployment.

### `OOMKilled`
The container exceeded its memory limit. Raise `limits.memory`, or find the
leak.

---

## Workload Identity (Pod → Firestore)

**Symptom:** `/readyz` returns 503, and the logs show a 403 from Firestore.
This is the most common sticking point in the tutorial. Work through it in
order.

**1. Is the annotation on the KSA, and is it real?**
```bash
kubectl get sa linkforge-api -n linkforge -o yaml | grep -A2 annotations
```
It must show your actual email, not `__API_GSA_EMAIL__`. A literal placeholder
means you applied raw manifests instead of using `scripts/deploy.sh`.

**2. Does the Google service account trust that exact KSA?**
```bash
gcloud iam service-accounts get-iam-policy \
  "linkforge-api@${PROJECT_ID}.iam.gserviceaccount.com"
```
You need `roles/iam.workloadIdentityUser` with the member exactly:
```
serviceAccount:PROJECT_ID.svc.id.goog[linkforge/linkforge-api]
```
Namespace, then `/`, then KSA name. Both must match your cluster exactly.

**3. Does the service account have Firestore access?**
```bash
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:linkforge-api@" \
  --format="value(bindings.role)"
```
Expected: `roles/datastore.user`. (There is no `roles/firestore.user` — Firestore
reuses the Datastore role names.)

**4. Ask a Pod who it thinks it is:**
```bash
kubectl run wi-test -n linkforge --rm -it --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"linkforge-api"}}' \
  --image="${IMAGE_REPO}/api:$(git rev-parse --short HEAD)" \
  --command -- sh -c \
  'wget -qO- --header="Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'
```
Expected: `linkforge-api@...`. If it prints the **node's** account
(`linkforge-gke-node@...`), impersonation is not happening — recheck 1 and 2.

**5. Is `GKE_METADATA` on for the node pool?**
```bash
gcloud container node-pools describe primary \
  --cluster "$CLUSTER_NAME" --zone "$ZONE" \
  --format="value(config.workloadMetadataConfig.mode)"
```
Expected: `GKE_METADATA`.

---

## Ingress and load balancer

### No `ADDRESS` after 15 minutes
```bash
kubectl describe ingress linkforge -n linkforge | tail -20
```
`Translation failed` usually means a Service named in the Ingress does not
exist or has no matching Pods.

### Backends stuck `UNHEALTHY`
```bash
kubectl describe ingress linkforge -n linkforge | grep -A5 Annotations
gcloud compute backend-services list --global
gcloud compute backend-services get-health BACKEND_NAME --global
```
Confirm the health-check path answers from inside the cluster:
```bash
kubectl exec -n linkforge -c api "$(kubectl get pod -n linkforge -l tier=api -o name | head -1 | cut -d/ -f2)" \
  -- wget -qO- http://localhost:8080/healthz
```

### 502 for the first few minutes
Normal. The IP appears before the backends pass their first health checks.
Wait 3 more minutes before investigating.

### `/` works but `/api/...` returns 404
The URL map sent it to the wrong backend.
```bash
kubectl get ingress linkforge -n linkforge -o yaml | grep -A8 paths
```
`/api` and `/r` must be listed **before** `/`, pointing at the `api` Service.

### 502 that never resolves
Port mismatch. The Service `targetPort` must reach container port 8080, and the
`BackendConfig` health-check port must match:
```bash
kubectl get svc -n linkforge -o wide
kubectl get backendconfig -n linkforge -o yaml | grep -A6 healthCheck
```

---

## GitHub Actions

### `Unable to acquire impersonated credentials`
The `attribute_condition` does not match your repository, or the
`principalSet` binding is wrong.
```bash
git remote -v                            # what repo are you really pushing to?
gcloud iam workload-identity-pools providers describe github-provider \
  --location=global --workload-identity-pool=github-pool \
  --format="value(attributeCondition)"
```
These must agree, including capitalisation. Fix `terraform.tfvars` and re-apply.

### `Missing or insufficient OIDC token permissions`
The workflow is missing `id-token: write` in its `permissions:` block.

### `denied: Permission "artifactregistry.repositories.uploadArtifacts" denied`
You never restored `writer_members` after the Chapter 03 workaround. Chapter 08,
Step 8.4, then `terraform apply`.

### `error: You must be logged in to the server (Unauthorized)`
`GKE_CLUSTER` or `GCP_ZONE` repository variable is wrong or missing.
```bash
gh variable list
```

### The workflow never runs
Check the `paths:` filter in the workflow file against what you actually
changed, and that you pushed to `main`.

---

## Application

### Web page loads but shows "Could not reach the API"
- **Before Chapter 07:** expected. There is no Ingress yet, and the production
  nginx config serves static files only.
- **After Chapter 07:** check `/api/version` directly with `curl`, then work
  through the Ingress section above.

### The browser shows an old version after a successful deploy
Hard-refresh (`Ctrl-Shift-R`). The nginx config sends `Cache-Control:
no-store`, but a service worker or a corporate proxy can still cache. Confirm
what is actually deployed with:
```bash
curl -s "http://${LINKFORGE_IP}/api/version"
```

### `422 Unprocessable Entity` creating a link
Pydantic rejected the URL. It only accepts `http` and `https` schemes, and
requires a full URL — `example.com` fails, `https://example.com` works. This is
deliberate: it closes an open-redirect vector.

### Click counts look wrong
Each click is one atomic `firestore.Increment(1)`. If a number seems high,
remember the browser may prefetch links, and `curl` without `-I` follows
redirects and would count twice.

---

## Cost

### The bill is higher than expected
```bash
gcloud compute forwarding-rules list --global   # ~$18/month each
gcloud compute addresses list                   # reserved-but-unused IPs bill
gcloud container clusters list                  # regional clusters cost 3x
gcloud compute disks list                       # orphaned disks
```
The usual culprits: a forgotten second Ingress, a reserved static IP nothing
uses, or a regional rather than zonal cluster.

### I destroyed everything but I am still being billed
Orphaned load balancer components — you deleted the cluster before the Ingress.
Run the orphan hunt in Chapter 12, Step 12.4.

---

## Still stuck

Gather this before asking anyone (or before opening a support case):

```bash
{
  echo "=== context ==="
  gcloud config get-value project
  kubectl config current-context
  echo "=== nodes ==="
  kubectl get nodes -o wide
  echo "=== workloads ==="
  kubectl get all -n linkforge
  echo "=== events ==="
  kubectl get events -n linkforge --sort-by=.lastTimestamp | tail -25
  echo "=== ingress ==="
  kubectl describe ingress linkforge -n linkforge
  echo "=== terraform ==="
  cd GCP/linkforge && terraform state list
} > /tmp/linkforge-debug.txt 2>&1

echo "Written to /tmp/linkforge-debug.txt"
```

Check it for anything sensitive before sharing it.
