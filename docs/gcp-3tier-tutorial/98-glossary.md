# Glossary

Every term this tutorial uses, in plain English. Skim it now; come back when
something reads like jargon.

---

## Google Cloud

**ADC (Application Default Credentials)** — The credential-discovery order that
Google's client libraries follow: an explicit key file, then
`gcloud auth application-default login` output, then the VM/Pod metadata
server. It is why the Python code in this lab never mentions credentials.

**Artifact Registry** — Google's container image (and package) registry.
Replaced Container Registry (`gcr.io`). Images are addressed as
`REGION-docker.pkg.dev/PROJECT/REPOSITORY/IMAGE:TAG`.

**Billing account** — The payment method a project is attached to. A project
with no billing account cannot create most resources, even free-tier ones.

**Cloud NAT** — A managed gateway giving VMs without external IPs access to the
public internet. ~$32/month. **Deliberately not used here** — see *Private
Google Access*.

**Firestore (Native mode)** — Serverless NoSQL document database. Data is
organised into *collections* of *documents*. Uses the older `roles/datastore.*`
IAM role names. Every project has exactly one primary database, named
`(default)`.

**Forwarding rule** — The Google Cloud object that owns a public IP and port.
This is the specific thing that costs ~$18/month when you create an Ingress.

**GKE (Google Kubernetes Engine)** — Managed Kubernetes. *Standard* mode lets
you manage node pools; *Autopilot* manages nodes for you and charges per Pod.

**IAM role** — A named bundle of permissions, e.g. `roles/datastore.user`.
Granted to a *member* (a user, a group, or a service account) on a *resource*
(a project, a bucket, or a single registry repository).

**Private Google Access** — A subnet setting that lets VMs **without** external
IPs reach Google APIs over Google's internal network, for free. The reason this
lab has private nodes and no NAT bill.

**Project** — The top-level container for resources, billing and IAM. The unit
you delete to be certain nothing survives. Project IDs are globally unique and
permanent.

**Service account (Google)** — A non-human identity that resources run as, e.g.
`linkforge-api@project.iam.gserviceaccount.com`.

**STS (Security Token Service)** — The Google service that swaps an external
OIDC token (from GitHub) for a Google federated token. The engine behind
Workload Identity Federation.

**Workload Identity** — Lets a **Kubernetes** ServiceAccount impersonate a
Google service account, so Pods get cloud credentials without a key file.

**Workload Identity Federation** — Lets an **external** system (GitHub Actions,
AWS, any OIDC provider) impersonate a Google service account without a key.
Same idea, different direction.

---

## Kubernetes

**Cordon / Drain** — `cordon` marks a node unschedulable; `drain` additionally
evicts everything already on it, respecting PodDisruptionBudgets.

**Deployment** — Manages a ReplicaSet, which manages Pods. Gives you rolling
updates, rollbacks and a declared replica count.

**Downward API** — Injecting information about the Pod into the Pod itself,
e.g. `POD_NAME` from `fieldRef: metadata.name`.

**HPA (HorizontalPodAutoscaler)** — Adds and removes Pod replicas based on a
metric, usually CPU relative to the *request*.

**Ingress** — A declaration of HTTP routing rules. On GKE, the `gce` ingress
controller turns one Ingress object into a global load balancer plus six other
Google Cloud resources.

**KSA (Kubernetes ServiceAccount)** — An in-cluster identity a Pod runs as. In
this lab it is annotated to point at a Google service account.

**Liveness probe** — "Should Kubernetes restart this container?" Must have **no
external dependencies**.

**Namespace** — A logical partition inside a cluster. A blast-radius boundary
and a unit of deletion.

**NEG (Network Endpoint Group)** — A Google Cloud list of Pod IP:port pairs.
What makes *container-native load balancing* possible: the load balancer talks
straight to Pods instead of via a node port.

**PDB (PodDisruptionBudget)** — "Never voluntarily take me below N available."
Makes `drain` wait rather than causing an outage.

**Pod** — The smallest deployable unit: one or more containers sharing a
network namespace and an IP.

**preStop hook** — A command run just before a container is signalled to stop.
Here, a 15-second sleep that lets the load balancer stop routing to a Pod
before it exits.

**Readiness probe** — "Should this Pod receive traffic right now?" This one
**should** check dependencies.

**Requests vs Limits** — *Request* is what the scheduler reserves; *limit* is a
hard ceiling. This lab sets a memory limit but deliberately **no CPU limit**,
because CPU limits throttle containers even on an idle node.

**RollingUpdate / maxUnavailable / maxSurge** — How a Deployment replaces Pods.
`maxUnavailable: 0` means a new Pod must be Ready before an old one is removed,
which is what makes the deploys here zero-downtime.

**Service** — A stable name and virtual IP in front of a set of Pods.
`ClusterIP` is internal-only, which is all you need when an Ingress fronts it.

**topologySpreadConstraints** — "Spread these Pods across nodes/zones." Why
draining one node does not take the API down.

---

## Terraform

**Backend** — Where state is stored. Here, a GCS bucket. *Partial
configuration* means the bucket name is supplied at `init` time rather than
hard-coded.

**`depends_on`** — An explicit ordering edge, for when one resource needs
another that it does not textually reference.

**Drift** — Reality diverging from state, usually because someone changed
something in the console. `terraform plan` is what detects it.

**Module** — A reusable folder of Terraform with inputs (variables) and
outputs.

**Plan / Apply** — `plan` shows what *would* change; `apply` does it. Applying
a **saved plan file** guarantees you get exactly what you reviewed.

**Provider** — The plugin that talks to an API, e.g. `hashicorp/google`. Pin
its major version or your configuration will behave differently on different
machines.

**Root module / stack** — The directory you actually run `terraform` in. Here,
`GCP/linkforge/`.

**State** — Terraform's map from configuration to real resources. Losing it
means Terraform no longer knows it owns your cluster.

---

## CI/CD and general

**Attribute condition** — A CEL expression restricting which external
identities may use a workload identity provider. The line that stops **any**
GitHub repository from assuming your service account. Google now requires one.

**Container-native load balancing** — Load balancer → Pod IP directly, no
kube-proxy hop. Enabled by the `cloud.google.com/neg` annotation.

**OIDC (OpenID Connect)** — An identity layer over OAuth 2.0. GitHub Actions
issues a signed OIDC token describing each run; Google verifies it.

**Repository variable vs secret (GitHub)** — Variables are visible; secrets are
masked. Because federation stores no credentials, everything this lab puts in
GitHub is a **variable** — which makes debugging much easier.

**Rolling update** — Replacing Pods gradually rather than all at once.

**Spot VM** — A heavily discounted VM Google can reclaim with 30 seconds
notice. ~70% cheaper, and a free lesson in graceful shutdown.

**VPC-native cluster** — A cluster where Pods get real, routable VPC IPs from a
subnet secondary range, rather than an overlay network. Required for NEGs.
