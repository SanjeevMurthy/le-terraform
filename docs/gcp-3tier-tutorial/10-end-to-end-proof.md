# Chapter 10 — Prove It End to End

⏱ ~15 minutes. This is the payoff chapter.

You are going to change one line of code, push it, and watch it reach
production without touching a terminal. Then you are going to **deliberately
break it**, and watch the pipeline catch and undo the damage on its own.

---

## Step 10.1 — Set up two windows

**What we're doing.** Arranging things so you can actually *watch* a
deployment happen, instead of running `kubectl get pods` afterwards and taking
it on faith.

**Terminal 1** — watch the Pods:

```bash
kubectl get pods -n linkforge --watch
```

**Terminal 2** — prove there is no downtime. This hits the site twice a second
and prints only the HTTP status:

```bash
source scripts/env.sh
while true; do
  printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' "http://${LINKFORGE_IP}/api/version")"
  sleep 0.5
done
```

You should see a steady stream of `200`. Leave both running.

**Browser** — open `http://${LINKFORGE_IP}` and note the version in the footer.

---

## Step 10.2 — Make a visible change

**What we're doing.** Changing something you can see from the outside, so
"did it deploy?" needs no interpretation.

**Edit `app/web/index.html`** and change the subtitle line:

```html
      <p class="sub">A very small URL shortener, running on GKE and Firestore.</p>
```

to something you will recognise:

```html
      <p class="sub">Shipped by a pipeline I built myself. No kubectl involved.</p>
```

**Do this.**

```bash
git add app/web/index.html
git commit -m "Update the LinkForge tagline"
git push
```

Note the commit SHA it prints — that is the version you are waiting for.

---

## Step 10.3 — Watch it ship

**In Terminal 3:**

```bash
gh run watch
```

**What happens, in order** (about 3–5 minutes):

**1. The `test` job runs.** 12 tests, ~20 seconds. Nothing is built until they
pass.

**2. Images build and push**, tagged with your new commit SHA.

**3. The rollout begins.** In **Terminal 1** you will see the rolling update
play out:

```
NAME                   READY   STATUS              RESTARTS   AGE
web-7c9d8f5b4c-hj3nq   1/1     Running             0          22m    ← old
web-7c9d8f5b4c-p8v2s   1/1     Running             0          22m    ← old
web-5f8a2c1e7b-k4m9x   0/1     Pending             0          1s     ← new
web-5f8a2c1e7b-k4m9x   0/1     ContainerCreating   0          3s
web-5f8a2c1e7b-k4m9x   1/1     Running             0          12s    ← new is Ready
web-7c9d8f5b4c-hj3nq   1/1     Terminating         0          22m    ← ONLY NOW does an old one go
web-5f8a2c1e7b-q7w3z   0/1     Pending             0          14s
...
```

Read that order carefully — it is `maxUnavailable: 0` doing its job. A new Pod
reaches `Running` and passes its readiness probe **before** any old Pod starts
terminating. At no point are there fewer than two serving Pods.

**4. In Terminal 2**, the stream of `200`s never breaks. Not one `502`, not one
timeout. That is the combination of `maxUnavailable: 0`, the `preStop` sleep,
and connection draining in the `BackendConfig` all doing their jobs together.

**5. Refresh the browser.** The new tagline is there, and the footer shows the
new commit SHA.

**Verify:**

```bash
curl -s "http://${LINKFORGE_IP}/api/version" | python3 -m json.tool
git rev-parse --short HEAD
```

The `version` field equals your commit SHA.

**Stop and consider what just happened.** You edited a file, ran `git push`,
and a container image was built, stored in a private registry, pulled onto
private nodes with no internet access, started, health-checked, added to a
global load balancer, and had its predecessor gracefully retired — with zero
dropped requests and no credential stored anywhere in the process.

That is the whole job, working.

---

## Step 10.4 — Now break it on purpose

**What we're doing.** Proving the safety net is real, by shipping something
genuinely broken.

**Why this matters more than the success case.** Any pipeline can deploy a
working change. What distinguishes a pipeline you can trust is what it does
with a broken one. You want to find that out now, on a URL shortener, rather
than at 2am on something that matters.

**Edit `app/api/Dockerfile`** and change the last line so the app listens on
the wrong port:

```dockerfile
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "9090"]
```

The container will start perfectly happily. It will just be listening on 9090
while Kubernetes health-checks 8080. Notice that the **unit tests still pass** —
they test the application, not the container's runtime configuration. This is a
realistic bug: the class of thing tests do not catch and health checks do.

**Do this.**

```bash
git add app/api/Dockerfile
git commit -m "Deliberately break the API port (this will roll back)"
git push
```

**Watch Terminal 1:**

```
api-9c2f1a8e5d-x3k7v   0/1     Running   0          10s    ← started, but never Ready
api-9c2f1a8e5d-x3k7v   0/1     Running   0          40s    ← still 0/1
api-9c2f1a8e5d-x3k7v   0/1     Running   0          90s    ← still 0/1
```

The new Pod is `Running` but stuck at `0/1` — the readiness probe against port
8080 gets connection-refused, so Kubernetes never marks it Ready and never
sends it traffic.

**Watch Terminal 2:** still `200`, unbroken. The old Pods are untouched,
because `maxUnavailable: 0` will not remove one until a replacement is Ready —
and none ever will be.

**Watch the Actions log:** after 180 seconds, `kubectl rollout status` times
out and the step fails:

```
error: timed out waiting for the condition
```

Then the `if: failure()` step runs:

```
Warning: Rollout failed, rolling back
deployment.apps/api rolled back
```

**Verify** the site is still serving the *previous* good version:

```bash
curl -s "http://${LINKFORGE_IP}/api/version" | python3 -m json.tool
```

The `version` is the SHA from Step 10.2 — the last good one — not the broken
commit.

```bash
kubectl get pods -n linkforge -l tier=api
kubectl rollout history deployment/api -n linkforge
```

**What just happened, and why nothing broke.** Three mechanisms combined:

1. **The readiness probe** correctly refused to declare a broken Pod healthy.
2. **`maxUnavailable: 0`** meant Kubernetes would not remove a working Pod
   until a replacement was Ready, so the broken deployment could never take
   capacity away.
3. **`rollout status` failing** gave the pipeline a signal to act on, and
   `rollout undo` returned the Deployment to its previous ReplicaSet.

Your users saw nothing. Not degraded service — *nothing*.

---

## Step 10.5 — Fix it

```bash
git revert --no-edit HEAD
git push
```

Watch it deploy cleanly. Confirm:

```bash
curl -s "http://${LINKFORGE_IP}/api/version" | python3 -m json.tool
kubectl get pods -n linkforge
```

All Pods `1/1 Running`, version equal to the revert commit.

> **Why `git revert` rather than `git reset`.** Revert adds a new commit that
> undoes the change, leaving history intact. `reset` plus a force-push
> rewrites history that CI, other clones and your own reflog already reference.
> On a shared branch, revert is almost always the right answer.

---

## Step 10.6 — What you can now say you have done

Every one of these is now something you have personally watched work:

- A commit triggering a test-gated build
- An image tagged immutably by commit and stored in a private registry
- A rolling update with genuinely zero dropped requests
- Readiness probes preventing a broken Pod from receiving traffic
- An automated rollback triggered by a failed rollout
- All of it authenticating with **no stored credentials** at any layer:
  - Pod → Firestore via Workload Identity
  - GitHub → Google Cloud via Workload Identity Federation
  - Docker → Artifact Registry via a gcloud credential helper
  - `kubectl` → GKE via the auth plugin

Stop the watch loops in Terminals 1 and 2 with `Ctrl-C`.

---

> ✅ **Checkpoint** — You have shipped a change through your own pipeline,
> broken production on purpose, and watched the system defend itself. The build
> is green and the site is live.

**Next:** [Chapter 11 — Day 2: run it](11-day2-operations.md)
