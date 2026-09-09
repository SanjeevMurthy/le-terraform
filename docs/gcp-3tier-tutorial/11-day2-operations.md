# Chapter 11 — Day 2: Run It

⏱ ~45 minutes. Six independent exercises — do them in any order, or stop after
whichever ones interest you.

Building infrastructure is the part people practise. Running it is the part
people get paid for, and the part interviews ask about. These are the six
things you will actually do most often.

---

## Exercise 1 — Find things in the logs

**What we're doing.** Going from "a user says it is broken" to "here is the
exact request that failed", using both `kubectl` and Cloud Logging.

### Quick look: kubectl

```bash
# All API Pods, following live
kubectl logs -n linkforge -l tier=api --tail=50 -f

# One specific Pod
kubectl logs -n linkforge api-6d4f7c8b9d-2xk4p

# The PREVIOUS container, after a crash. This is the one people forget, and
# it is the only place a crash loop's real error is visible.
kubectl logs -n linkforge api-6d4f7c8b9d-2xk4p --previous
```

Generate something to look at:

```bash
curl -s -X POST "http://${LINKFORGE_IP}/api/links" \
  -H 'Content-Type: application/json' \
  -d '{"target_url":"https://kubernetes.io/docs/concepts/"}' > /dev/null
curl -s "http://${LINKFORGE_IP}/r/doesnotexist" > /dev/null
```

You will see JSON lines like:

```json
{"severity":"INFO","message":"created short code k3f9x2p -> https://kubernetes.io/docs/concepts/","logger":"linkforge","version":"a1b2c3d","pod":"api-6d4f7c8b9d-2xk4p"}
```

### The real thing: Cloud Logging

Every one of those lines is already in Cloud Logging, parsed — you configured
nothing to make that happen. Because the application emits JSON with a
`severity` field, `severity` is a **real, filterable field** rather than text
you have to grep.

```bash
# Errors and warnings from the API, last hour
gcloud logging read '
  resource.type="k8s_container"
  resource.labels.namespace_name="linkforge"
  labels."k8s-pod/tier"="api"
  severity>=WARNING
' --limit=20 --format="table(timestamp, severity, jsonPayload.message)" --freshness=1h

# Everything one specific Pod said
gcloud logging read '
  resource.type="k8s_container"
  resource.labels.pod_name="api-6d4f7c8b9d-2xk4p"
' --limit=50 --format="value(timestamp, jsonPayload.message)"

# Trace a single short code across every replica
gcloud logging read '
  resource.type="k8s_container"
  resource.labels.namespace_name="linkforge"
  jsonPayload.message:"k3f9x2p"
' --limit=20 --format="value(timestamp, jsonPayload.pod, jsonPayload.message)"
```

The same queries work in the console at **Logging → Logs Explorer**.

> **Why this is worth the twenty lines of logging setup in `main.py`.** With
> plain `print()` statements, every line arrives as `textPayload` with severity
> `DEFAULT`. You cannot filter by level, cannot query by field, and cannot
> alert on error rate. Twenty lines of formatter turns your logs from a wall of
> text into a queryable dataset — and it is free.

---

## Exercise 2 — Read the metrics

**What we're doing.** Finding out what your cluster is actually doing.

```bash
# Per-node CPU and memory (needs a minute or two of history after a restart)
kubectl top nodes

# Per-Pod
kubectl top pods -n linkforge

# What is REQUESTED vs what is available -- the numbers the scheduler uses
kubectl describe node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" \
  | grep -A8 "Allocated resources"
```

Expected, roughly:

```
NAME                   CPU(cores)   MEMORY(bytes)
api-6d4f7c8b9d-2xk4p   3m           68Mi
web-7c9d8f5b4c-hj3nq   1m           12Mi
```

Note how far below the requests (50m CPU, 128Mi) actual usage sits. Requests
are a **reservation for the scheduler**, not a measurement — this is why "the
node says 80% allocated but 5% used" is normal and not a bug.

In the console: **Kubernetes Engine → Workloads** gives per-Deployment CPU,
memory and error-rate charts with no setup.

---

## Exercise 3 — Autoscale under real load

**What we're doing.** Adding a HorizontalPodAutoscaler, generating genuine
traffic, and watching Kubernetes add Pods.

### First, remove the conflict

**Edit `k8s/12-api-deployment.yaml` and delete the `replicas: 2` line.**

This matters. If both the Deployment manifest and the HPA specify a replica
count, every `kubectl apply` resets it to 2 and undoes whatever the autoscaler
just decided. Pods appear and disappear for no visible reason, and it is a
genuinely maddening bug to track down. The rule: **whoever owns the replica
count owns it alone.**

### Apply the HPA

**Create `k8s/day2/api-hpa.yaml`:**

```yaml
# Applied by hand in Chapter 11, NOT part of the normal deploy.
#
# Before applying: delete the "replicas:" line from k8s/12-api-deployment.yaml.
# If you leave it, every deploy resets the replica count and undoes whatever
# the autoscaler just decided. This is the single most common HPA bug.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
  namespace: linkforge
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          # Percentage of the *request* (50m), not of a whole core. At 60%,
          # sustained usage above 30m per Pod triggers a scale-up.
          averageUtilization: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
    scaleDown:
      # Scale down slowly. Reacting instantly to a dip causes flapping.
      stabilizationWindowSeconds: 180
```

```bash
kubectl apply -f k8s/day2/api-hpa.yaml
kubectl get hpa -n linkforge
```

Expected — `<unknown>` for the first minute is normal while metrics arrive:

```
NAME   REFERENCE        TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
api    Deployment/api   4%/60%    2         6         2          45s
```

### Generate load

**Create `scripts/loadgen.sh`:**

```bash
#!/usr/bin/env bash
# Hammer a short link so the HorizontalPodAutoscaler has something to react to.
#
#   ./scripts/loadgen.sh http://34.120.0.1/r/ab12cd3          # 60s, 20 workers
#   ./scripts/loadgen.sh http://34.120.0.1/r/ab12cd3 120 40   # 120s, 40 workers
#
# Runs from your laptop on purpose. Generating load from inside the cluster
# would compete with the very Pods you are trying to measure, and the nodes in
# this lab have no route to the public internet anyway.

set -euo pipefail

URL="${1:?usage: loadgen.sh URL [DURATION_SECONDS] [WORKERS]}"
DURATION="${2:-60}"
WORKERS="${3:-20}"

echo "==> ${WORKERS} workers hitting ${URL} for ${DURATION}s"
echo "    Watch it work in another terminal:"
echo "      kubectl get hpa api -n linkforge --watch"
echo

END=$(( $(date +%s) + DURATION ))
for _ in $(seq 1 "${WORKERS}"); do
  (
    while [[ $(date +%s) -lt ${END} ]]; do
      # -o /dev/null discards the body, -w prints nothing; we only care that
      # the request happened. Redirects are NOT followed: we are load testing
      # LinkForge, not whatever site the link points at.
      curl -s -o /dev/null "${URL}" || true
    done
  ) &
done
wait

echo "==> Load finished. Scale-down takes ~3 minutes (see the HPA's"
echo "    scaleDown.stabilizationWindowSeconds)."
```

Make a link to hammer, then run it:

```bash
source scripts/env.sh
CODE=$(curl -s -X POST "http://${LINKFORGE_IP}/api/links" \
  -H 'Content-Type: application/json' \
  -d '{"target_url":"https://example.com"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])')

chmod +x scripts/loadgen.sh
./scripts/loadgen.sh "http://${LINKFORGE_IP}/r/${CODE}" 180 30
```

In another terminal:

```bash
kubectl get hpa api -n linkforge --watch
```

**What you will see**, over about three minutes:

```
NAME   TARGETS    MINPODS   MAXPODS   REPLICAS
api    4%/60%     2         6         2          ← idle
api    120%/60%   2         6         2          ← load arrives
api    120%/60%   2         6         4          ← HPA scales up
api    71%/60%    2         6         4
api    68%/60%    2         6         5
api    45%/60%    2         6         5          ← stabilised
```

And the Pods appearing:

```bash
kubectl get pods -n linkforge -l tier=api --watch
```

**Why the target is a percentage of the *request*, not of a core.** The
request is 50m. At `averageUtilization: 60`, sustained usage above 30m per Pod
triggers a scale-up. This is why setting a sensible request matters even
though it is "only" a scheduling hint — the HPA's whole arithmetic is
relative to it.

When the load stops, scale-down takes about **three minutes**
(`scaleDown.stabilizationWindowSeconds: 180`). That delay is deliberate:
reacting instantly to a dip causes flapping, where the HPA removes Pods,
load per Pod rises, and it immediately adds them back.

```bash
kubectl describe hpa api -n linkforge | tail -12
```

The Events section narrates every decision it made and why.

> **What this does *not* do:** the HPA adds Pods, but the cluster still has
> exactly two nodes. If it scaled to a point where Pods could not fit, they
> would sit `Pending` forever. In production you would pair the HPA with the
> **cluster autoscaler** (`autoscaling { min_node_count, max_node_count }` on
> the node pool) so nodes are added too. It is left off here to keep costs
> predictable — a good next exercise once you are done.

---

## Exercise 4 — Survive losing a node

**What we're doing.** Deliberately evicting everything from one node and
watching the workload survive. This is exactly what happens during a GKE
upgrade, and what a Spot preemption does to you without warning.

```bash
kubectl get pods -n linkforge -o wide     # note which node each Pod is on
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

# cordon: mark unschedulable, but leave running Pods alone
kubectl cordon "$NODE"
kubectl get nodes

# drain: evict everything, respecting PodDisruptionBudgets
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```

Keep the status loop from Chapter 10 running in another terminal. It stays at
`200` throughout.

**What just happened.** Three mechanisms cooperating:

1. **The PodDisruptionBudget** (`minAvailable: 1`) made `drain` wait rather
   than evicting both API Pods at once. Without it, drain takes everything
   immediately and you get a real outage during a routine node upgrade.
2. **`topologySpreadConstraints`** had already placed the replicas on
   different nodes, so one always survived.
3. **The preStop sleep and connection draining** let in-flight requests finish
   on the Pod being evicted.

Put the node back:

```bash
kubectl uncordon "$NODE"
kubectl get pods -n linkforge -o wide
```

Note that Pods do **not** move back on their own. Kubernetes does not
rebalance existing Pods — they go where they were scheduled and stay there.
Deleting a Pod lets the scheduler place it fresh.

> **Spot nodes do this to you for free.** If a node disappears during this lab
> with no action from you, Google reclaimed it. Now you know exactly what
> happens next, and why nothing broke.

---

## Exercise 5 — Roll back by hand

Chapter 10 covered automatic rollback. Sometimes you need to do it yourself,
because the deploy succeeded and the code is simply wrong.

```bash
kubectl rollout history deployment/api -n linkforge

# What is running right now
kubectl get deployment api -n linkforge -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

# Back one revision
kubectl rollout undo deployment/api -n linkforge

# Or to a specific one
kubectl rollout undo deployment/api -n linkforge --to-revision=3

kubectl rollout status deployment/api -n linkforge
```

**A caveat worth internalising.** `rollout undo` changes the cluster but not
your git repository. The next push from `main` will deploy the bad version
again, because git is still the source of truth. Treat a manual rollback as
**buying time**, then immediately `git revert` the offending commit. An
undocumented manual rollback that gets silently re-applied an hour later is a
classic incident-inside-an-incident.

---

## Exercise 6 — Debug a Pod that will not start

**What we're doing.** Building the reflex of checking things in the right
order. In practice, `describe` before `logs` finds the problem more often.

```bash
# 1. WHAT is wrong -- the Events at the bottom are the useful part
kubectl describe pod -n linkforge POD_NAME

# 2. What did the process say
kubectl logs -n linkforge POD_NAME
kubectl logs -n linkforge POD_NAME --previous     # after a crash loop

# 3. Cluster-wide recent events, newest last
kubectl get events -n linkforge --sort-by=.lastTimestamp | tail -20

# 4. Get inside a running container
kubectl exec -it -n linkforge POD_NAME -- sh

# 5. Talk to a Service from inside the cluster (DNS included)
kubectl run debug -n linkforge --rm -it --restart=Never \
  --image="${IMAGE_REPO}/api:$(git rev-parse --short HEAD)" \
  --command -- sh -c 'wget -qO- http://api.linkforge.svc.cluster.local/healthz'
```

**The status-to-cause lookup table:**

| Status | Almost always means |
|---|---|
| `ImagePullBackOff` | Wrong image name/tag, no pull permission, **or a public image your private nodes cannot reach** |
| `CrashLoopBackOff` | The process starts and exits. `logs --previous` has the reason |
| `Pending` | No node has room. `describe` shows the scheduler's exact complaint |
| `Running` but `0/1` | Readiness probe failing. Wrong port or path |
| `OOMKilled` | Exceeded its memory limit. Raise the limit or fix the leak |
| `CreateContainerConfigError` | A referenced ConfigMap or Secret does not exist |

> Remember the debug Pod uses **your own image** from Artifact Registry. Your
> nodes have no route to Docker Hub, so `--image=busybox` will sit in
> `ImagePullBackOff` — which is, conveniently, a live demonstration of the
> first row of that table.

---

## Optional: what to do next

Genuinely useful extensions, roughly in order of value:

| Extension | What it teaches |
|---|---|
| **Cluster autoscaler** — add `autoscaling {}` to the node pool | Nodes scaling with demand, and the HPA/CA interaction |
| **HTTPS** — a domain + `ManagedCertificate` | Real TLS, and the DNS-validation dance (Chapter 07, Step 7.6) |
| **Alerting** — a Cloud Monitoring policy on 5xx rate | Getting told, instead of finding out |
| **Kustomize overlays** — a `dev` and `prod` variant | The manifest-templating problem `sed` is standing in for |
| **`terraform plan` in a PR gate** | Branch protection on infrastructure (Chapter 09, Step 9.6) |
| **Swap Firestore for Cloud SQL** | VPC peering, private IP, proxy sidecars, secret rotation (Chapter 00, §6) |
| **NetworkPolicy** | Stopping the web tier from reaching the API directly, in-cluster |
| **A `staging` namespace** | Environment promotion with one cluster |

---

> ✅ **Checkpoint** — You can find a specific request in the logs, read your
> cluster's real resource usage, autoscale under load, survive losing a node,
> roll back deliberately, and debug a Pod that will not start. That is the
> operational half of the job.

**Next:** [Chapter 12 — Cost control & teardown](12-cost-control-and-teardown.md)
