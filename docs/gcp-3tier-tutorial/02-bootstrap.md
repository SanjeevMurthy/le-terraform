# Chapter 02 — Bootstrap the Project

⏱ ~15 minutes. This is the only chapter where you create cloud resources by
hand instead of with Terraform.

---

## Step 2.0 — Why any of this is manual

**What we're doing.** Understanding why we do not just `terraform apply` from
line one.

Terraform needs somewhere to keep its state file, and that somewhere is a
Cloud Storage bucket. But Terraform cannot create the bucket that holds its
own state — where would it record having created it? This is the classic
**bootstrap chicken-and-egg**, and every team hits it.

The three standard answers:

1. **Create the bucket by hand, once.** What we do. Four commands, never
   repeated, easy to explain to the next person.
2. **A second "bootstrap" Terraform stack with local state**, committed to
   git. Cleaner in theory; in practice a state file in git that nobody
   remembers to update.
3. **Let a platform team hand you a bucket.** What happens at most companies,
   which is why engineers often never see this problem.

The same reasoning applies to the first two API enablements below: Terraform
enables APIs by calling the Service Usage API, which has to be enabled before
Terraform can call it.

So: five manual commands, then Terraform owns everything for the rest of the
tutorial.

---

## Step 2.1 — Create the project

**What we're doing.** Creating an empty Google Cloud project — the container
that everything else lives in and, importantly, the boundary you delete at the
end to be certain nothing is left running.

**Do this.**

```bash
source scripts/env.sh

gcloud projects create "$PROJECT_ID" --name="LinkForge Lab"
```

**What just happened.** A new, empty project now exists. It has no billing
account, no APIs enabled and no resources. Takes about 10 seconds.

If your Google account belongs to an organisation, you may need to say where
the project goes:

```bash
gcloud organizations list          # find your org ID
gcloud projects create "$PROJECT_ID" --name="LinkForge Lab" --organization=YOUR_ORG_ID
```

**Verify.**

```bash
gcloud projects describe "$PROJECT_ID" --format="value(projectId,lifecycleState)"
```

Expected:

```
linkforge-lab-4821	ACTIVE
```

**If it breaks.**

- *`Requested entity already exists`* — someone, somewhere on Earth, already
  owns that project ID. Pick another (Step 1.6), update `scripts/env.sh`,
  `source` it again.
- *`Permission denied` / `does not have permission to create projects`* —
  your account cannot create projects in that organisation. Ask an admin, or
  use a personal Google account with the free trial.

---

## Step 2.2 — Attach billing

**What we're doing.** Linking the billing account you found in Step 1.2.

**Why this matters.** Without it, every resource creation in the next chapter
fails with `BILLING_DISABLED` — including things that would cost nothing.

**Do this.** Replace the ID with your own from `gcloud billing accounts list`:

```bash
export BILLING_ACCOUNT_ID="01A2B3-C4D5E6-F7G8H9"

gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"
```

**Verify.**

```bash
gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)"
```

Expected: `True`. If it says `False`, nothing after this point will work.

---

## Step 2.3 — Make this project the default

**What we're doing.** Saving yourself from typing `--project` on every command
for the rest of the tutorial.

**Do this.**

```bash
gcloud config set project "$PROJECT_ID"
```

**Verify.**

```bash
gcloud config get-value project
```

Expected: your project ID.

> ⚠️ If you use several GCP projects, get in the habit of running that
> `get-value` check before any destructive command. Running `terraform
> destroy` against the wrong default project is a genuinely bad afternoon.

---

## Step 2.4 — Enable the two seed APIs

**What we're doing.** Turning on the two APIs that let Terraform turn on all
the others.

**Why only two.** Terraform's `google_project_service` resources in
`GCP/linkforge/main.tf` will enable the remaining seven (Compute, GKE,
Artifact Registry, Firestore, IAM, IAM Credentials, STS). But it can only do
that by calling the Service Usage API — so that one, and the Cloud Resource
Manager API it depends on, have to be on first.

**Do this.**

```bash
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com
```

**What just happened.** Takes 20–60 seconds. Enabling an API is a
project-level switch: it makes the endpoint callable and does not by itself
cost anything.

**Verify.**

```bash
gcloud services list --enabled --format="value(config.name)" | grep -E "serviceusage|cloudresourcemanager"
```

Expected: both lines present.

---

## Step 2.5 — Create the Terraform state bucket

**What we're doing.** Creating the Cloud Storage bucket that will hold
`terraform.tfstate`.

**Why remote state at all.** The state file is Terraform's map of which real
cloud resources correspond to which lines of your configuration. Keeping it
on your laptop means:

- GitHub Actions cannot see it, so CI and you would each build a *separate*
  copy of the infrastructure;
- there is no locking, so two simultaneous applies can corrupt it;
- losing your laptop means Terraform no longer knows it owns your cluster.

The GCS backend fixes all three: shared, automatically locked during an
apply, and versioned.

**Do this.**

```bash
gcloud storage buckets create "gs://${TF_STATE_BUCKET}" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --uniform-bucket-level-access \
  --public-access-prevention
```

Then turn on object versioning:

```bash
gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning
```

**What just happened.** Three flags worth understanding:

- `--uniform-bucket-level-access` disables per-object ACLs, so access is
  governed purely by IAM. Fewer ways to accidentally make state public.
- `--public-access-prevention` makes "public" impossible even if someone later
  tries. Your state file contains resource IDs, IP ranges and sometimes
  generated passwords — it is not something to leave open.
- `--versioning` keeps every previous version of the state file. If an apply
  ever corrupts state, you can restore yesterday's. This has saved more
  careers than any other single flag in this tutorial.

**Optional but recommended** — stop old state versions accumulating forever:

```bash
cat > /tmp/lifecycle.json <<'JSON'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"daysSinceNoncurrentTime": 30, "numNewerVersions": 5}
    }
  ]
}
JSON

gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --lifecycle-file=/tmp/lifecycle.json
```

That keeps at least the 5 most recent versions, and deletes superseded ones
after 30 days.

**Verify.**

```bash
gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" \
  --format="value(name,location,versioning.enabled,iamConfiguration.uniformBucketLevelAccess.enabled)"
```

Expected:

```
tf-state-linkforge-lab-4821	US-CENTRAL1	True	True
```

**If it breaks.**

- *`HTTPError 409: Your previous request to create the named bucket succeeded`*
  — you already made it. Fine, move on.
- *`The requested bucket name is not available`* — bucket names are globally
  unique too. Pick another, update `scripts/env.sh`, `source` it, retry.
- *`billing account for project is disabled`* — go back to Step 2.2.

---

## Step 2.6 — Confirm the whole bootstrap

**Do this.**

```bash
echo "Project:  $(gcloud config get-value project)"
echo "Billing:  $(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)')"
echo "Bucket:   $(gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" --format='value(name)')"
echo "Region:   ${REGION} / Zone: ${ZONE}"
```

Expected — four lines, all populated, no errors:

```
Project:  linkforge-lab-4821
Billing:  True
Bucket:   tf-state-linkforge-lab-4821
Region:   us-central1 / Zone: us-central1-a
```

---

## What this cost

Nothing. An empty project is free, and a bucket holding a few kilobytes of
state is inside the 5 GB Always Free allowance.

---

> ✅ **Checkpoint** — You have a billing-enabled GCP project set as your
> gcloud default, two seed APIs on, and a versioned, private state bucket.
> Everything from here on is Terraform.

**Next:** [Chapter 03 — Terraform: the foundation](03-terraform-foundation.md)
