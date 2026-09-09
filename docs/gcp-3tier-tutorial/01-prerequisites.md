# Chapter 01 — Prerequisites & Your Settings Sheet

⏱ ~20 minutes. Mostly installing things.

---

## Step 1.1 — What you need before you start

**What we're doing.** Getting four tools and one Google Cloud account in
place. Everything after this chapter assumes they work.

**Do this.** Install whichever of these you are missing.

| Tool | Minimum | Install | Check |
|---|---|---|---|
| `gcloud` CLI | any recent | [cloud.google.com/sdk/docs/install](https://cloud.google.com/sdk/docs/install) | `gcloud version` |
| `terraform` | 1.5+ | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) | `terraform version` |
| `kubectl` | 1.28+ | `gcloud components install kubectl` | `kubectl version --client` |
| `docker` | any recent | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) | `docker version` |
| `git` | any | you have it | `git --version` |

One extra GKE-specific component. `kubectl` cannot authenticate to a GKE
cluster without it, and the error it produces when missing is famously
unhelpful:

```bash
gcloud components install gke-gcloud-auth-plugin
```

If you installed gcloud from a Linux package manager rather than the archive,
`gcloud components install` is disabled. Use your package manager instead:

```bash
# Debian/Ubuntu
sudo apt-get install google-cloud-cli-gke-gcloud-auth-plugin
```

**Verify.**

```bash
gcloud version && terraform version && kubectl version --client && docker version --format '{{.Client.Version}}'
gke-gcloud-auth-plugin --version
```

You want five successful outputs and no "command not found".

---

## Step 1.2 — A Google Cloud account with billing

**What we're doing.** Making sure you can actually create billable resources.

**Why this matters.** GKE, Artifact Registry and load balancers all refuse to
be created in a project with no billing account attached — even when
everything you are creating is inside the free tier. "Free tier" means
"charged at $0", not "no billing account needed".

**Do this.**

1. Go to [console.cloud.google.com](https://console.cloud.google.com).
2. If you have never used GCP, accept the free trial. You get **$300 in
   credits, valid for 90 days**, which covers this lab many times over.
3. Find your billing account ID:

```bash
gcloud auth login
gcloud billing accounts list
```

**What just happened.** `gcloud auth login` opened a browser and stored your
user credentials locally. `billing accounts list` printed something like:

```
ACCOUNT_ID            NAME                OPEN  MASTER_ACCOUNT_ID
01A2B3-C4D5E6-F7G8H9  My Billing Account  True
```

Copy that `ACCOUNT_ID`. You need it in the next chapter.

**If it breaks.**

- *Empty list, no error* — you have no billing account. Create one at
  [console.cloud.google.com/billing](https://console.cloud.google.com/billing).
- *`OPEN` is `False`* — the account is closed or the trial expired. Nothing in
  this lab will work until that is fixed.

---

## Step 1.3 — Two more Google logins (and why there are two)

**What we're doing.** Authenticating twice, in two different ways.

**Why this way.** This trips up almost everyone once, so it is worth 60
seconds now:

- `gcloud auth login` authenticates **you**, for `gcloud` commands.
- `gcloud auth application-default login` writes a separate credential file
  that **libraries and tools** read — Terraform's Google provider, the Python
  Firestore client, and anything else using "Application Default Credentials"
  (ADC).

They are stored separately. Doing only the first and then running `terraform
plan` produces `could not find default credentials`, and the fix is not
obvious if you do not know there are two.

**Do this.**

```bash
gcloud auth application-default login
```

**Verify.**

```bash
gcloud auth list                       # your user account, marked ACTIVE
ls ~/.config/gcloud/application_default_credentials.json
```

Both should succeed.

---

## Step 1.4 — Get the repository

**What we're doing.** Getting a copy of this repository that you can push to,
because Chapter 09's pipeline triggers on pushes to *your* repo.

**Do this.** If you are reading this inside your own clone already, skip ahead.
Otherwise fork or clone it, then:

```bash
cd le-terraform
git remote -v          # confirm "origin" points at YOUR GitHub account
```

**Why it must be your own repo.** Chapter 08 configures Google Cloud to trust
tokens issued for one specific GitHub repository. If `origin` points at
someone else's, your workflow runs will authenticate as a repo that GCP has
never heard of, and fail.

---

## Step 1.5 — Fill in your settings sheet

**What we're doing.** Writing your project ID and region down **once**, in a
file every later command reads.

**Why this way.** The alternative is retyping your project ID into 40
commands, getting it wrong in three of them, and spending an hour on errors
that have nothing to do with the thing you are learning.

**Create this file** by copying the template:

```bash
cp scripts/env.sh.example scripts/env.sh
```

Here is what the template contains:

```bash
# ---------------------------------------------------------------------------
# Your one and only settings file. Fill it in once in Chapter 01.
#
#   cp scripts/env.sh.example scripts/env.sh
#   $EDITOR scripts/env.sh
#   source scripts/env.sh
#
# Every command in the tutorial reads these, so you never have to remember
# your project ID again. scripts/env.sh is gitignored.
# ---------------------------------------------------------------------------

# --- who you are ----------------------------------------------------------
export PROJECT_ID="REPLACE-ME"                 # e.g. linkforge-lab-4821
export REGION="us-central1"
export ZONE="us-central1-a"

# --- what Terraform will name things (defaults are fine) ------------------
export CLUSTER_NAME="linkforge-gke"
export AR_REPO="linkforge"
export NAMESPACE="linkforge"

# --- created by hand in Chapter 02 ----------------------------------------
export TF_STATE_BUCKET="REPLACE-ME"            # e.g. tf-state-linkforge-lab-4821

# --- your GitHub repository -----------------------------------------------
export GITHUB_OWNER="REPLACE-ME"
export GITHUB_REPO="le-terraform"

# --- derived; leave these alone -------------------------------------------
export REGISTRY_HOST="${REGION}-docker.pkg.dev"
export IMAGE_REPO="${REGISTRY_HOST}/${PROJECT_ID}/${AR_REPO}"
export API_GSA_EMAIL="linkforge-api@${PROJECT_ID}.iam.gserviceaccount.com"
```

**Now edit `scripts/env.sh`** and set the four `REPLACE-ME` values:

| Variable | What to put | Notes |
|---|---|---|
| `PROJECT_ID` | e.g. `linkforge-lab-4821` | Must be **globally unique across all of Google Cloud**, 6–30 characters, lowercase letters/digits/hyphens. Add random digits. You will create it in the next chapter |
| `TF_STATE_BUCKET` | e.g. `tf-state-linkforge-lab-4821` | Also globally unique. Convention: `tf-state-` + your project ID |
| `GITHUB_OWNER` | your GitHub username or org | Exactly as it appears in your repo URL |
| `GITHUB_REPO` | `le-terraform` | Repository name only, no owner prefix |

Leave `REGION`, `ZONE` and the derived variables alone unless you have a
reason. `us-central1` is used throughout because it is one of the regions
covered by Compute Engine's Always Free tier.

**Do this** every time you open a new terminal for this project:

```bash
source scripts/env.sh
```

**Verify.**

```bash
echo "$PROJECT_ID"
echo "$IMAGE_REPO"
```

Expected — with your own values, and critically **no `REPLACE-ME` anywhere**:

```
linkforge-lab-4821
us-central1-docker.pkg.dev/linkforge-lab-4821/linkforge
```

**What just happened.** `IMAGE_REPO` and `API_GSA_EMAIL` were assembled from
the values you set, so they can never disagree with them. `scripts/env.sh` is
in `.gitignore`, so your settings stay yours.

**If it breaks.**

- *`IMAGE_REPO` contains `REPLACE-ME`* — you edited the file but forgot to
  `source` it again. Re-run `source scripts/env.sh`.
- *`bash: scripts/env.sh: No such file`* — you are not in the repository root.

---

## Step 1.6 — Choose a project ID that will actually work

**What we're doing.** Avoiding the single most common wasted 20 minutes of
this whole tutorial.

Project IDs are **globally unique across every Google Cloud customer** and
**permanently immutable**. `linkforge` and `linkforge-lab` are long gone. If
you pick one that is taken, project creation fails with a message that sounds
like a permissions problem.

A safe pattern:

```bash
echo "linkforge-lab-$RANDOM"
```

Put that in `scripts/env.sh` as your `PROJECT_ID`, and `tf-state-` plus the
same string as your `TF_STATE_BUCKET`.

---

> ✅ **Checkpoint** — You have five working CLI tools, a billing account ID
> written down, two kinds of Google credentials on disk, your own clone of the
> repository, and a `scripts/env.sh` that produces sensible values when you
> `source` it. Still $0 spent.

**Next:** [Chapter 02 — Bootstrap the project](02-bootstrap.md)
