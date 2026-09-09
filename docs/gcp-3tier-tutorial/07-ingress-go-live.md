# Chapter 07 — Go Live with an Ingress

⏱ ~20 minutes, of which 5–8 is waiting for Google to build a load balancer.

This is the short chapter where it becomes a real, public, working
application.

---

## Step 7.0 — What an Ingress actually is

**What we're doing.** Understanding what those thirty lines of YAML cause to
happen, because on GKE it is more than it looks.

A Kubernetes `Ingress` is a *declaration*: "HTTP traffic arriving from outside
should be routed to these Services by these rules." It does nothing on its
own. An **ingress controller** watches for Ingress objects and creates real
infrastructure to satisfy them.

On GKE, `ingressClassName: gce` selects the controller built into the cluster,
and applying one Ingress makes it create **seven** Google Cloud resources:

| Created for you | What it is |
|---|---|
| Global forwarding rule | The public IP and port 80 |
| Target HTTP proxy | Terminates the connection |
| URL map | The path routing rules — `/api`, `/r`, `/` |
| 2 × Backend service | One per Kubernetes Service, with its health check and timeouts |
| 2 × Network Endpoint Group | The live list of Pod IPs (this is the NEG annotation paying off) |
| Health checks | Built from your `BackendConfig` |
| Firewall rules | Allowing Google's health checkers in |

You will not create any of those by hand. That is the point of Kubernetes: you
declare intent, a controller reconciles reality to match. If you delete a Pod,
the NEG updates within seconds. If you delete the Ingress, all seven are
cleaned up.

> 💸 **This is the file that costs money.** A global forwarding rule is about
> **$0.025/hour — roughly $18/month**. It is the single largest line in this
> lab's bill. Chapter 12 shows how to switch it off between sessions;
> `kubectl delete ingress linkforge -n linkforge` stops the charge in seconds.

---

## Step 7.1 — Path-based routing, and why it matters

**What we're doing.** Sending three URL prefixes to two different Services
behind one IP address.

```
                       http://34.120.55.10
                                │
                    ┌───────────▼────────────┐
                    │  URL map (longest      │
                    │  matching prefix wins) │
                    └──┬─────────┬─────────┬─┘
              /api ────┘         │         └──── /
              /r ────────────────┘              (everything else)
                    │                                  │
              ┌─────▼──────┐                    ┌──────▼─────┐
              │ api Service│                    │ web Service│
              └────────────┘                    └────────────┘
```

**Why one Ingress rather than two `type: LoadBalancer` Services.** Two
LoadBalancer Services would give you two public IPs, cost twice as much, and —
most importantly — put the frontend and the API on **different origins**. That
forces you to configure CORS, and to inject the API's address into the frontend
at build or run time, which means a different image per environment.

One origin with path routing avoids all of it. The frontend calls
`/api/links`, the browser sees one origin, and the same image runs everywhere.

---

## Step 7.2 — Create the Ingress

**Create `k8s/30-ingress.yaml`:**

```yaml
# ---------------------------------------------------------------------------
# The front door. THIS IS THE FILE THAT COSTS MONEY.
# ---------------------------------------------------------------------------
# Applying it creates a Google Cloud external HTTP load balancer: roughly
# $0.025/hour, about $18/month. Delete the Ingress when you are done for the
# day and the charge stops:
#
#     kubectl delete ingress linkforge -n linkforge
#
# Everything else in this lab is on a free tier or a few dollars a month.
#
# The routing here is what makes this a real 3-tier application rather than
# two unrelated services: ONE hostname, ONE public IP, and the load balancer
# decides which tier answers based on the path. Because the browser talks to
# one origin, the frontend JavaScript can call "/api/links" as a relative
# path -- no CORS, no API hostname compiled into the image.
#
# Longest matching prefix wins, so /api and /r reach the API and everything
# else falls through to the web tier.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: linkforge
  namespace: linkforge
  annotations:
    # HTTP only, to keep the lab free. For HTTPS you would add a
    # ManagedCertificate plus a domain you control -- see Chapter 11.
    kubernetes.io/ingress.allow-http: "true"
spec:
  # "gce" selects the Google Cloud Load Balancer controller built into GKE.
  ingressClassName: gce
  rules:
    - http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  number: 80
          - path: /r
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
```

**Do this.**

```bash
source scripts/env.sh
./scripts/deploy.sh
```

(`deploy.sh` applies everything in `k8s/`, so this picks up the new Ingress
along with the unchanged Deployments.)

**What just happened.** The Ingress object was created immediately. The load
balancer behind it was **not** — Google is now provisioning and propagating
seven resources across its global network. That takes **5–8 minutes on first
creation**, sometimes a little longer.

This is the single most common place people think something is broken when it
is merely slow. It is not broken. Watch it happen:

```bash
kubectl get ingress linkforge -n linkforge --watch
```

At first:

```
NAME        CLASS   HOSTS   ADDRESS   PORTS   AGE
linkforge   gce     *                 80      15s
```

Then, a few minutes later, an `ADDRESS` appears:

```
NAME        CLASS   HOSTS   ADDRESS         PORTS   AGE
linkforge   gce     *       34.120.55.10    80      6m
```

`Ctrl-C` out of the watch.

> An IP appearing does **not** mean it is serving yet. The backends still have
> to pass their first health checks. Expect another 1–3 minutes of `502 Server
> Error` after the IP shows up. This is normal. Wait before debugging.

---

## Step 7.3 — Watch the backends become healthy

**What we're doing.** Watching the load balancer decide your Pods are fit to
receive traffic, so you can tell "still warming up" from "actually broken".

```bash
kubectl describe ingress linkforge -n linkforge | grep -A10 Annotations
```

Look for the `backends` annotation. It goes through these states:

```
{"k8s1-...-api-80-...":"Unknown","k8s1-...-web-80-...":"Unknown"}     ← just created
{"k8s1-...-api-80-...":"HEALTHY","k8s1-...-web-80-...":"Unknown"}     ← getting there
{"k8s1-...-api-80-...":"HEALTHY","k8s1-...-web-80-...":"HEALTHY"}     ← ready
```

`Unknown` for the first few minutes is expected. **`UNHEALTHY` persisting past
five minutes is a real problem** — see Step 7.5.

---

## Step 7.4 — Use your application

**Do this.**

```bash
export LINKFORGE_IP=$(kubectl get ingress linkforge -n linkforge \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "http://${LINKFORGE_IP}"
```

Open that URL in a browser.

**Verify, the fun way:**

1. The LinkForge page loads.
2. Paste a long URL and press **Shorten**. A row appears.
3. Click the short link. You land on the target site.
4. Press **Refresh**. The click count is `1`.
5. The footer shows `api version a1b2c3d` and a pod name like
   `api-6d4f7c8b9d-2xk4p`.
6. **Refresh a few more times.** The pod name flips between your two API
   replicas — you are watching the load balancer distribute requests across
   Pods, live.

**Verify, the terminal way:**

```bash
curl -s "http://${LINKFORGE_IP}/api/version"; echo

CODE=$(curl -s -X POST "http://${LINKFORGE_IP}/api/links" \
  -H 'Content-Type: application/json' \
  -d '{"target_url":"https://cloud.google.com/kubernetes-engine/docs"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])')

echo "Short link: http://${LINKFORGE_IP}/r/${CODE}"

# -I shows headers only, and does NOT follow the redirect -- we want to see it.
curl -sI "http://${LINKFORGE_IP}/r/${CODE}" | head -3

curl -s "http://${LINKFORGE_IP}/api/links" | python3 -m json.tool | head -12
```

Expected:

```
{"version":"a1b2c3d","pod":"api-6d4f7c8b9d-2xk4p","project":"linkforge-lab-4821"}
Short link: http://34.120.55.10/r/k3f9x2p
HTTP/1.1 302 Found
Location: https://cloud.google.com/kubernetes-engine/docs
```

**Save the IP** — you will use it in the next few chapters:

```bash
echo "export LINKFORGE_IP=${LINKFORGE_IP}" >> scripts/env.sh
```

**Prove the path routing is real:**

```bash
curl -s "http://${LINKFORGE_IP}/"            | head -3   # web tier: HTML
curl -s "http://${LINKFORGE_IP}/api/version"             # api tier: JSON
curl -sI "http://${LINKFORGE_IP}/r/${CODE}"  | head -1   # api tier: 302
```

Three paths, one IP, two different Services answering. That is a three-tier
application on Kubernetes.

---

## Step 7.5 — If it does not work

Ingress problems are almost always one of five things. In likelihood order:

**1. You are not being patient enough.** 5–8 minutes for the IP, another 1–3
for health checks. Before debugging anything, confirm it has actually been ten
minutes.

**2. Backends stuck `UNHEALTHY`.** The load balancer cannot get a 200 from
your health check path.

```bash
gcloud compute backend-services list --global
gcloud compute backend-services get-health BACKEND_SERVICE_NAME --global
```

Check the path is right and answers from inside the cluster:

```bash
kubectl run curl-test -n linkforge --rm -it --restart=Never \
  --image="${IMAGE_REPO}/api:$(git rev-parse --short HEAD)" \
  --command -- sh -c 'wget -qO- http://api.linkforge.svc.cluster.local/healthz'
```

Expected: `{"status":"ok",...}`. If that fails, the problem is in the Service
or the Pods, not the load balancer.

**3. 404 on `/api/...` but `/` works.** The URL map routed to the wrong
backend. Confirm the Ingress paths:

```bash
kubectl get ingress linkforge -n linkforge -o yaml | grep -A6 paths
```

`/api` and `/r` must appear **before** `/` and point at the `api` Service.

**4. 502 that never resolves.** Usually a port mismatch: the Service's
`targetPort` must reach the container's real port (8080), and the
`BackendConfig` health check port must match too.

```bash
kubectl get svc -n linkforge -o wide
kubectl get backendconfig -n linkforge -o yaml | grep -A6 healthCheck
```

**5. No `ADDRESS` at all after 15 minutes.** Look at the Ingress events:

```bash
kubectl describe ingress linkforge -n linkforge | tail -20
```

`Translation failed` usually means a Service named in the Ingress does not
exist or has no matching Pods. Quota errors appear here too.

---

## Step 7.6 — About HTTPS

This lab runs HTTP only, deliberately: HTTPS on GKE needs a domain you
actually control, and buying one is not a thing a tutorial should require.

When you do have a domain, it is two objects:

```yaml
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: linkforge-cert
  namespace: linkforge
spec:
  domains:
    - linkforge.yourdomain.com
```

plus, on the Ingress:

```yaml
  annotations:
    networking.gke.io/managed-certificates: linkforge-cert
    kubernetes.io/ingress.allow-http: "false"
```

Point an `A` record at the Ingress IP first — Google validates domain ownership
by resolving it, and the certificate stays `Provisioning` until DNS is correct.
Issuance takes 15–60 minutes. The certificate itself is free and auto-renews.

---

## What this now costs

| | Per month |
|---|---|
| Cluster + nodes + disks | ~$10 |
| **HTTP load balancer** | **~$18** |
| **Total** | **~$28** |

The load balancer is now the majority of your bill. `kubectl delete ingress
linkforge -n linkforge` stops that charge whenever you are not using it, and
`./scripts/deploy.sh` brings it back (with a new IP, and another 5–8 minute
wait).

---

> ✅ **Checkpoint** — LinkForge is live on a public IP. One load balancer
> routes three paths to two tiers, the API talks to Firestore with no
> credentials, and you can hand the URL to someone else and they can use it.
> The remaining chapters make it deploy itself.

**Next:** [Chapter 08 — Keyless CI/CD authentication](08-github-workload-identity-federation.md)
