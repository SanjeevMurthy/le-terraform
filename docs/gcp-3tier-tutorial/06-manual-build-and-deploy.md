# Chapter 06 — Build and Deploy by Hand

⏱ ~25 minutes.

You are going to do manually, once, exactly what Chapter 09's pipeline will do
automatically forever. This is deliberate: automating a process you have never
performed yourself produces someone who cannot debug it when it breaks at 2am.

---

## Step 6.1 — Teach Docker to authenticate to Artifact Registry

**What we're doing.** Configuring Docker to send your Google credentials when
it talks to `us-central1-docker.pkg.dev`.

**Why it is needed.** Artifact Registry is a private registry. A plain `docker
push` gets a `401 Unauthorized`, because Docker has no idea it should be using
your gcloud identity.

**Do this.**

```bash
source scripts/env.sh
gcloud auth configure-docker "${REGISTRY_HOST}" --quiet
```

**What just happened.** gcloud added a `credHelper` entry to
`~/.docker/config.json` mapping that hostname to `gcloud`. From now on, when
Docker talks to that registry it shells out to gcloud for a fresh token. No
password is stored — the same pattern as everything else in this lab.

**Verify.**

```bash
grep -A3 credHelpers ~/.docker/config.json
```

Expected: a line containing `"us-central1-docker.pkg.dev": "gcloud"`.

---

## Step 6.2 — Build and push both images

**What we're doing.** Building the two images and pushing them to your
registry, tagged with the current git commit.

**Why the git SHA as the tag, and never `latest`.** Three concrete failures
`latest` causes:

1. Two Pods started an hour apart can be running **different code** while both
   claiming to be `latest`.
2. `kubectl rollout undo` has nothing to roll back *to* — the previous version
   has the same tag.
3. "Which commit is in production?" becomes genuinely unanswerable.

An immutable tag makes every running Pod traceable to exactly one commit.

**Create `scripts/build-and-push.sh`:**

```bash
#!/usr/bin/env bash
# Build both container images and push them to Artifact Registry.
#
#   source scripts/env.sh
#   ./scripts/build-and-push.sh              # tag = current git short SHA
#   ./scripts/build-and-push.sh v1           # tag = v1
#
# Why the git SHA and not "latest": "latest" is a moving target. If two Pods
# start at different times they can silently run different code, and
# "kubectl rollout undo" has nothing to roll back to. An immutable tag makes
# every deployment traceable to one commit.

set -euo pipefail

: "${PROJECT_ID:?run: source scripts/env.sh}"
: "${IMAGE_REPO:?run: source scripts/env.sh}"

TAG="${1:-$(git rev-parse --short HEAD)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building tag: ${TAG}"
echo "    api -> ${IMAGE_REPO}/api:${TAG}"
echo "    web -> ${IMAGE_REPO}/web:${TAG}"
echo

# --platform is not optional if you are on an Apple Silicon Mac. Without it
# you build arm64 images, push them happily, and then watch every Pod fail
# with "exec format error" on the amd64 nodes.
docker build --platform linux/amd64 -t "${IMAGE_REPO}/api:${TAG}" "${ROOT}/app/api"
docker build --platform linux/amd64 -t "${IMAGE_REPO}/web:${TAG}" "${ROOT}/app/web"

echo
echo "==> Pushing"
docker push "${IMAGE_REPO}/api:${TAG}"
docker push "${IMAGE_REPO}/web:${TAG}"

echo
echo "==> Done. Deploy with:"
echo "    ./scripts/deploy.sh ${TAG}"
```

Make it executable and run it:

```bash
chmod +x scripts/*.sh
./scripts/build-and-push.sh
```

**What just happened.** Two images built and pushed, roughly 2–4 minutes on a
first run. Note `--platform linux/amd64` in the script: on an Apple Silicon Mac
you would otherwise build arm64 images, push them without complaint, and then
watch every Pod fail with `exec format error` — a genuinely baffling failure
if you do not know to look for it.

**Verify** the images really landed:

```bash
gcloud artifacts docker images list "${IMAGE_REPO}" --include-tags
```

Expected — two rows, both tagged with your short SHA:

```
IMAGE                                                              TAGS     ...
us-central1-docker.pkg.dev/linkforge-lab-4821/linkforge/api        a1b2c3d
us-central1-docker.pkg.dev/linkforge-lab-4821/linkforge/web        a1b2c3d
```

**If it breaks.**

- *`denied: Permission "artifactregistry.repositories.uploadArtifacts" denied`*
  — you are pushing to the wrong project, or Step 6.1 did not take. Check
  `echo $IMAGE_REPO` and `gcloud config get-value project`.
- *`docker: command not found` / daemon not running* — start Docker Desktop.
- *`name unknown: Repository "linkforge" not found`* — Chapter 03's apply did
  not create it. `gcloud artifacts repositories list --location=$REGION`.

---

## Step 6.3 — The Kubernetes manifests

**What we're doing.** Writing the YAML that describes what should run.

**Why placeholders like `__API_IMAGE__`.** The image tag changes on every
commit, and the project ID differs per person. Hard-coding either means the
manifests in git are wrong for everybody except whoever committed last.
`scripts/deploy.sh` substitutes them at deploy time. Helm and Kustomize solve
the same problem with more features; `sed` is the version where you can see
exactly what is happening.

Create each of these files.

**`k8s/00-namespace.yaml`:**

```yaml
# A namespace is a blast-radius boundary. Everything LinkForge owns lives
# here, so "what did I deploy?" and "delete all of it" are both one command.
apiVersion: v1
kind: Namespace
metadata:
  name: linkforge
  labels:
    app: linkforge
```

**`k8s/10-api-serviceaccount.yaml`** — the Kubernetes half of the Workload
Identity handshake from Chapter 04:

```yaml
# The Kubernetes half of Workload Identity.
#
# Terraform created the Google service account and told it to trust this exact
# KSA. This annotation is the other half of that handshake: it tells the GKE
# metadata server "when a Pod using this KSA asks for credentials, hand it a
# token for that Google service account".
#
# Get the string wrong and you do not get an error at deploy time -- you get a
# 403 from Firestore at request time. Check it first when /readyz fails.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: linkforge-api
  namespace: linkforge
  annotations:
    iam.gke.io/gcp-service-account: __API_GSA_EMAIL__
```

**`k8s/11-api-backendconfig.yaml`:**

```yaml
# BackendConfig is a GKE-specific CRD that configures the Google Cloud load
# balancer backend sitting in front of this Service.
#
# Without it, the load balancer guesses a health check from your readiness
# probe. That guess is right often enough that people skip this file -- and
# then spend an afternoon staring at a backend stuck in UNHEALTHY. Being
# explicit costs 12 lines.
#
# Note which endpoint it checks: /healthz, not /readyz. If Firestore goes
# down, we want the load balancer to keep routing to the API so users get a
# clear error page. Marking every backend UNHEALTHY would give them a bare
# 502 from Google instead.
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: api
  namespace: linkforge
spec:
  healthCheck:
    type: HTTP
    requestPath: /healthz
    port: 8080
    checkIntervalSec: 15
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
  timeoutSec: 30
  # Give in-flight requests time to finish when a Pod is removed.
  connectionDraining:
    drainingTimeoutSec: 30
```

**`k8s/12-api-deployment.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: linkforge
  labels:
    app: linkforge
    tier: api
spec:
  # NOTE: once you apply the HorizontalPodAutoscaler in Chapter 11, DELETE the
  # "replicas" line below. Otherwise every kubectl apply resets the replica
  # count and fights the autoscaler.
  replicas: 2
  selector:
    matchLabels:
      app: linkforge
      tier: api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      # maxUnavailable: 0 means a new Pod must be Ready before an old one is
      # removed. This is what makes the deploy in Chapter 10 zero-downtime.
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: linkforge
        tier: api
    spec:
      serviceAccountName: linkforge-api
      # Give the load balancer time to stop sending new requests to this Pod
      # before the process exits. Without it you get a handful of 502s on
      # every single deploy, which people wrongly blame on the app.
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      # Spread the replicas over different nodes when possible, so draining
      # one node does not take the whole API down.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: linkforge
              tier: api
      containers:
        - name: api
          image: __API_IMAGE__
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: GOOGLE_CLOUD_PROJECT
              value: __GCP_PROJECT_ID__
            - name: APP_VERSION
              value: __APP_VERSION__
            # The downward API: Kubernetes injects the Pod's own name. The web
            # UI displays it, which makes load balancing visible.
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              # Memory limit: yes. Exceeding it is a bug and OOMKill is the
              # correct, obvious signal.
              memory: 256Mi
              # CPU limit: deliberately absent. A CPU limit throttles the
              # container even when the node is idle, which shows up as
              # mysterious latency. The 50m request is what the scheduler
              # uses; bursting above it when capacity exists is free.
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                # Container-native load balancing takes a few seconds to stop
                # sending traffic to a terminating Pod. Sleeping here absorbs
                # that gap instead of dropping the requests in it.
                command: ["/bin/sleep", "15"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        # readOnlyRootFilesystem is on, so anything that needs to write needs
        # an explicit, non-executable scratch volume.
        - name: tmp
          emptyDir: {}
```

**`k8s/13-api-service.yaml`:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: linkforge
  annotations:
    # Container-native load balancing. Without this the load balancer sends
    # traffic to node ports and kube-proxy does a second hop to a random Pod,
    # which costs latency and hides the real client IP. With it, the load
    # balancer talks straight to Pod IPs.
    cloud.google.com/neg: '{"ingress": true}'
    # Attach the BackendConfig from 11-api-backendconfig.yaml.
    cloud.google.com/backend-config: '{"default": "api"}'
spec:
  type: ClusterIP
  selector:
    app: linkforge
    tier: api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

**`k8s/14-api-pdb.yaml`:**

```yaml
# A PodDisruptionBudget tells Kubernetes "never voluntarily take me below one
# available replica". It is what makes `kubectl drain` wait for a replacement
# Pod instead of yanking both at once during a node upgrade.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api
  namespace: linkforge
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: linkforge
      tier: api
```

**`k8s/20-web-backendconfig.yaml`:**

```yaml
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: web
  namespace: linkforge
spec:
  healthCheck:
    type: HTTP
    requestPath: /healthz
    port: 8080
    checkIntervalSec: 15
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 3
  timeoutSec: 30
```

**`k8s/21-web-deployment.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: linkforge
  labels:
    app: linkforge
    tier: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: linkforge
      tier: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: linkforge
        tier: web
    spec:
      terminationGracePeriodSeconds: 45
      securityContext:
        # 101 is the nginx user inside the nginx-unprivileged image.
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: linkforge
              tier: web
      containers:
        - name: web
          image: __WEB_IMAGE__
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              memory: 64Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 10
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sleep", "15"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            # Deliberately NOT read-only. The nginx entrypoint writes to
            # /etc/nginx and /var/cache/nginx on startup. The clean fix is to
            # serve the config from a ConfigMap and mount emptyDirs over both
            # paths -- a good exercise once the rest of this works.
            readOnlyRootFilesystem: false
```

**`k8s/22-web-service.yaml`:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: linkforge
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
    cloud.google.com/backend-config: '{"default": "web"}'
spec:
  type: ClusterIP
  selector:
    app: linkforge
    tier: web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

---

### The five decisions buried in that YAML

**1. Memory limit yes, CPU limit no.** A memory limit is right: exceeding it is
a bug, and `OOMKilled` is a clear signal. A CPU limit is different — it
*throttles* the container even when the node is completely idle, producing
latency that looks like an application problem and is not. The `requests` value
is what the scheduler uses to place the Pod; bursting above it when there is
spare capacity is free. This is one of the most common causes of mysterious
slowness in Kubernetes.

**2. `maxUnavailable: 0`.** During a rolling update, a new Pod must become
Ready before an old one is removed. This is what makes Chapter 10's deploy
zero-downtime, and it is also why a failed rollout is safe: the old Pods are
still serving while the new ones fail to start.

**3. `preStop: sleep 15`.** When a Pod is deleted, Kubernetes signals the
container and removes it from the Service simultaneously. The Google load
balancer takes a few seconds to notice. Without a pause, requests arrive at a
process that is already shutting down — a handful of 502s on every deploy,
which people reliably blame on the application. Sleeping absorbs the gap.

**4. `cloud.google.com/neg: '{"ingress": true}'` on the Services.** This turns
on container-native load balancing: the load balancer sends traffic **straight
to Pod IPs** rather than to a node port that kube-proxy then forwards to a
random Pod. One less network hop, and the real client IP survives.

**5. The `BackendConfig` health check points at `/healthz`, not `/readyz`.**
If Firestore went down and the load balancer checked `/readyz`, every backend
would be marked UNHEALTHY and users would get a bare Google 502. Checking
`/healthz` keeps traffic flowing to the API so it can return a clear,
actionable error instead. Kubernetes readiness still uses `/readyz`, which is
the right layer for that decision.

---

## Step 6.4 — The deploy script

**Create `scripts/deploy.sh`:**

```bash
#!/usr/bin/env bash
# Render the Kubernetes manifests and apply them.
#
#   source scripts/env.sh
#   ./scripts/deploy.sh                 # deploy the current git short SHA
#   ./scripts/deploy.sh v1              # deploy a specific tag
#   RENDER_ONLY=1 ./scripts/deploy.sh   # print the rendered YAML, apply nothing
#   SKIP_INGRESS=1 ./scripts/deploy.sh  # skip the Ingress (the billable part)
#
# The manifests in k8s/ contain __PLACEHOLDERS__ instead of real image names,
# because an image tag changes on every commit and a project ID differs per
# person. Substituting at deploy time keeps the manifests in git generic and
# readable. (Kustomize or Helm do the same job with more features; this is the
# zero-dependency version so you can see exactly what is happening.)

set -euo pipefail

: "${PROJECT_ID:?run: source scripts/env.sh}"
: "${IMAGE_REPO:?run: source scripts/env.sh}"
: "${NAMESPACE:?run: source scripts/env.sh}"
: "${API_GSA_EMAIL:?run: source scripts/env.sh}"

TAG="${1:-$(git rev-parse --short HEAD)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

for manifest in "${ROOT}"/k8s/*.yaml; do
  name="$(basename "${manifest}")"
  if [[ -n "${SKIP_INGRESS:-}" && "${name}" == *ingress* ]]; then
    echo "==> Skipping ${name} (SKIP_INGRESS set)"
    continue
  fi
  sed \
    -e "s|__API_IMAGE__|${IMAGE_REPO}/api:${TAG}|g" \
    -e "s|__WEB_IMAGE__|${IMAGE_REPO}/web:${TAG}|g" \
    -e "s|__GCP_PROJECT_ID__|${PROJECT_ID}|g" \
    -e "s|__API_GSA_EMAIL__|${API_GSA_EMAIL}|g" \
    -e "s|__APP_VERSION__|${TAG}|g" \
    "${manifest}" > "${RENDER_DIR}/${name}"
done

# Fail loudly rather than shipping a manifest with a literal "__API_IMAGE__"
# in it, which Kubernetes would accept and then fail to pull.
if grep -rq '__[A-Z_]*__' "${RENDER_DIR}"; then
  echo "ERROR: unsubstituted placeholders remain:" >&2
  grep -rn '__[A-Z_]*__' "${RENDER_DIR}" >&2
  exit 1
fi

if [[ -n "${RENDER_ONLY:-}" ]]; then
  # Separate each file with "---". kubectl apply -f DIR reads files one at a
  # time so it does not care, but a bare concatenation is not valid YAML and
  # would break anything you piped this into.
  for rendered in "${RENDER_DIR}"/*.yaml; do
    echo "---"
    echo "# source: k8s/$(basename "${rendered}")"
    cat "${rendered}"
  done
  exit 0
fi

echo "==> Applying tag ${TAG} to namespace ${NAMESPACE}"
kubectl apply -f "${RENDER_DIR}"

echo
echo "==> Waiting for rollouts"
kubectl rollout status deployment/api -n "${NAMESPACE}" --timeout=180s
kubectl rollout status deployment/web -n "${NAMESPACE}" --timeout=180s

echo
echo "==> Deployed. Current state:"
kubectl get pods,svc,ingress -n "${NAMESPACE}"
```

**Look at what it produces before applying anything:**

```bash
source scripts/env.sh
RENDER_ONLY=1 ./scripts/deploy.sh | head -40
```

You should see real values where the placeholders were — your project ID, your
image path with your commit SHA, your service account email. The script also
greps for any `__PLACEHOLDER__` it failed to substitute and refuses to
continue, because Kubernetes would happily accept a manifest with a literal
`__API_IMAGE__` in it and then fail to pull.

---

## Step 6.5 — Deploy

**Do this.**

```bash
./scripts/deploy.sh
```

**What just happened.** Roughly 60–90 seconds:

1. Manifests rendered with your image tag.
2. `kubectl apply` created the namespace, service account, backend configs,
   deployments, services and PDB.
3. Kubernetes scheduled four Pods (2 api + 2 web) across your two nodes.
4. Each node pulled the images from Artifact Registry **over Private Google
   Access** — no public IP, no NAT.
5. `kubectl rollout status` waited until both Deployments reported all replicas
   Ready.

Expected:

```
deployment "api" successfully rolled out
deployment "web" successfully rolled out

NAME                       READY   STATUS    RESTARTS   AGE
pod/api-6d4f7c8b9d-2xk4p   1/1     Running   0          62s
pod/api-6d4f7c8b9d-9wm7t   1/1     Running   0          62s
pod/web-7c9d8f5b4c-hj3nq   1/1     Running   0          61s
pod/web-7c9d8f5b4c-p8v2s   1/1     Running   0          61s
```

---

## Step 6.6 — Verify each tier separately

**What we're doing.** Proving tier 2 and tier 3 work, then tier 1 — before
wiring them together with an Ingress in the next chapter.

> **Expected limitation.** There is no Ingress yet, so the full UI will not
> work end to end. If you port-forward the web tier and open it, the page loads
> but shows "Could not reach the API" — because in production nginx serves only
> static files and the Ingress is what routes `/api`. That is correct
> behaviour at this stage, not a bug. Chapter 07 connects them.

### Tier 2 + 3: the API and Firestore

`port-forward` opens a tunnel from your laptop straight to a Pod, bypassing
Services and load balancers entirely. It is the cleanest way to test one thing
at a time.

```bash
kubectl port-forward -n linkforge svc/api 8080:80
```

In a second terminal:

```bash
curl -s localhost:8080/healthz;  echo
curl -s localhost:8080/readyz;   echo
curl -s -X POST localhost:8080/api/links \
  -H 'Content-Type: application/json' \
  -d '{"target_url":"https://cloud.google.com/kubernetes-engine/docs"}'; echo
curl -s localhost:8080/api/links; echo
```

Expected:

```json
{"status":"ok","version":"a1b2c3d"}
{"status":"ready","version":"a1b2c3d"}
{"code":"k3f9x2p","target_url":"https://cloud.google.com/kubernetes-engine/docs","clicks":0,...}
[{"code":"k3f9x2p",...}]
```

**That `{"status":"ready"}` is the moment Workload Identity is proven.** A Pod
with no credential file, no mounted secret and no environment variable holding
a key just authenticated to Firestore and read from it. The full chain worked:
Pod → KSA → annotation → Google service account → `roles/datastore.user` →
Firestore.

**Confirm it independently, from Firestore's side:**

```bash
gcloud firestore documents list --collection-ids=links --limit=5 \
  --format="value(name)" 2>/dev/null || \
  echo "(if this command is unavailable in your gcloud version, check the Firestore console instead)"
```

Stop the port-forward with `Ctrl-C`.

### Tier 1: the web Pod

```bash
kubectl port-forward -n linkforge svc/web 8081:80
curl -s localhost:8081/healthz; echo
curl -s localhost:8081/ | head -5
```

Expected: `ok`, then the first lines of `index.html`. Stop with `Ctrl-C`.

---

## Step 6.7 — When `/readyz` returns 503

This is the most likely place in the entire tutorial to get stuck, and it is
almost always Workload Identity. Work through it in this order:

**1. Read the actual error.** The API returns the reason, not just a status:

```bash
kubectl logs -n linkforge -l tier=api --tail=30
```

A `403 Permission denied on resource project ...` or `... does not have
datastore.entities.list access` confirms it is Workload Identity.

**2. Check the KSA annotation resolved correctly:**

```bash
kubectl get serviceaccount linkforge-api -n linkforge -o yaml | grep -A2 annotations
```

Must show your **real** email, not `__API_GSA_EMAIL__`:

```yaml
  annotations:
    iam.gke.io/gcp-service-account: linkforge-api@linkforge-lab-4821.iam.gserviceaccount.com
```

**3. Check the IAM binding on the Google side:**

```bash
gcloud iam service-accounts get-iam-policy \
  "linkforge-api@${PROJECT_ID}.iam.gserviceaccount.com" \
  --format=json
```

You need a `roles/iam.workloadIdentityUser` binding whose member is exactly:

```
serviceAccount:YOUR_PROJECT_ID.svc.id.goog[linkforge/linkforge-api]
```

Namespace and KSA name inside the square brackets, separated by `/`. A
mismatch here — wrong namespace, wrong name — is the classic cause.

**4. Ask a throwaway Pod who it thinks it is:**

```bash
kubectl run wi-test -n linkforge --rm -it --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"linkforge-api"}}' \
  --image="${IMAGE_REPO}/api:$(git rev-parse --short HEAD)" \
  --command -- sh -c \
  'wget -qO- --header="Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'
```

Expected: `linkforge-api@YOUR_PROJECT.iam.gserviceaccount.com`

If it prints the **node's** service account (`linkforge-gke-node@...`) instead,
the impersonation is not happening — recheck steps 2 and 3.

> Note the `--image` uses **your own** image from Artifact Registry, not a
> public one. Your nodes have no route to Docker Hub, so `--image=busybox`
> would sit in `ImagePullBackOff` forever. This is that trade-off from Chapter
> 03 showing up in practice.

---

## What this now costs

Unchanged from Chapter 04 — roughly **$10/month**. Four small Pods on nodes you
are already paying for cost nothing extra, and Firestore is inside the free
tier.

---

> ✅ **Checkpoint** — Your images are in Artifact Registry. Four Pods are
> running in GKE. The API talks to Firestore with no credentials anywhere.
> There is still no public URL — that is the next chapter, and it is short.

**Next:** [Chapter 07 — Go live with an Ingress](07-ingress-go-live.md)
