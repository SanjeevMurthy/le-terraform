# Chapter 05 — The Application

⏱ ~30 minutes. No cloud resources are created here, and nothing is billed. By
the end you will have LinkForge running on your laptop against a local
Firestore emulator, with tests passing.

---

## Step 5.0 — Why we run it locally first

**What we're doing.** Building and testing the application entirely on your
machine, before it goes anywhere near GKE.

**Why this way.** When something breaks after a deployment, the first question
is always "is it the code, or is it the infrastructure?" If you have never run
the code outside the cluster, you cannot answer that, and you end up debugging
Kubernetes when the real problem is a typo in a Python file.

Ten minutes here removes an entire category of confusion from the next three
chapters.

---

## Step 5.1 — What the API does

**Six endpoints**, and each one exists for a reason:

| Method | Path | Purpose | Why it is here |
|---|---|---|---|
| `GET` | `/healthz` | "Is the process alive?" | Kubernetes **liveness** probe and the load balancer health check |
| `GET` | `/readyz` | "Can it reach Firestore?" | Kubernetes **readiness** probe |
| `GET` | `/api/version` | Build tag + Pod name | How you prove in Chapter 10 that a deploy landed |
| `POST` | `/api/links` | Create a short code | The core write path |
| `GET` | `/api/links` | List 50 newest | The core read path |
| `DELETE` | `/api/links/{code}` | Remove a link | So the demo does not accumulate junk |
| `GET` | `/r/{code}` | 302 redirect, count the click | The actual product |

**The liveness/readiness split is not busywork.** It is the single most
commonly botched thing in a Kubernetes deployment, so:

- **Liveness** answers *"should Kubernetes restart this container?"* It must
  have **no external dependencies**. If you check Firestore here and Firestore
  has a two-minute blip, every Pod fails liveness, Kubernetes restarts all of
  them simultaneously, and you have converted a brief upstream hiccup into a
  full self-inflicted outage.
- **Readiness** answers *"should this Pod receive traffic right now?"* This
  one **should** check dependencies. A Pod that cannot reach Firestore should
  be taken out of the load balancer rotation, not killed.

There is a test in the suite that asserts `/healthz` never touches the
database, so this cannot silently regress.

---

## Step 5.2 — The API code

**Create `app/api/main.py`:**

```python
"""LinkForge API -- the microservice tier of the 3-tier lab.

Responsibilities:
  * create short codes and store them in Firestore
  * list recent links
  * resolve a short code and 302-redirect, incrementing a click counter

Deliberately small. The interesting engineering in this project is the
infrastructure around it, not the 200 lines below.

Authentication to Firestore uses Application Default Credentials. In GKE that
resolves through Workload Identity to a Google service account -- there is no
key file, no password, and no secret anywhere in this container.
"""

from __future__ import annotations

import json
import logging
import os
import random
import string
import sys
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse, RedirectResponse
from google.api_core import exceptions as gcloud_exceptions
from google.cloud import firestore
from pydantic import BaseModel, Field, HttpUrl

# ---------------------------------------------------------------------------
# Configuration -- everything comes from the environment, nothing is hardcoded
# ---------------------------------------------------------------------------
PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
COLLECTION = os.environ.get("LINKFORGE_COLLECTION", "links")
APP_VERSION = os.environ.get("APP_VERSION", "dev")
# Injected by Kubernetes via the downward API. Showing it in the UI makes
# load balancing across replicas visible: refresh and watch the name change.
POD_NAME = os.environ.get("POD_NAME", "local")
CODE_ALPHABET = string.ascii_lowercase + string.digits
CODE_LENGTH = 7
MAX_CODE_ATTEMPTS = 5
LIST_LIMIT = 50


# ---------------------------------------------------------------------------
# Structured logging
# ---------------------------------------------------------------------------
# Cloud Logging parses stdout as JSON when the fields are named correctly.
# "severity" becomes the log level in the console and "message" the summary,
# which means you can filter by severity in Logs Explorer instead of grepping.
class CloudLoggingFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "version": APP_VERSION,
            "pod": POD_NAME,
        }
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry)


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(CloudLoggingFormatter())
logging.basicConfig(level=logging.INFO, handlers=[_handler], force=True)
log = logging.getLogger("linkforge")


# ---------------------------------------------------------------------------
# Firestore client -- created lazily, on purpose
# ---------------------------------------------------------------------------
# If we built the client at import time and credentials were not ready, the
# process would crash before it could serve /healthz. The container would then
# CrashLoopBackOff with no useful signal. Lazy init means the process starts,
# /healthz answers, and /readyz reports the real problem.
_db: firestore.Client | None = None


def get_db() -> firestore.Client:
    global _db
    if _db is None:
        _db = firestore.Client(project=PROJECT_ID or None)
    return _db


# ---------------------------------------------------------------------------
# API models
# ---------------------------------------------------------------------------
class CreateLinkRequest(BaseModel):
    target_url: HttpUrl = Field(..., description="The long URL to shorten.")


class Link(BaseModel):
    code: str
    target_url: str
    clicks: int
    created_at: str | None = None
    short_path: str


def _to_link(code: str, data: dict[str, Any]) -> Link:
    created = data.get("created_at")
    return Link(
        code=code,
        target_url=data.get("target_url", ""),
        clicks=int(data.get("clicks", 0)),
        created_at=created.isoformat() if isinstance(created, datetime) else None,
        short_path=f"/r/{code}",
    )


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(
    title="LinkForge API",
    version=APP_VERSION,
    description="URL shortener microservice backed by Firestore.",
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
)


@app.exception_handler(gcloud_exceptions.GoogleAPICallError)
def firestore_error_handler(_: Request, exc: gcloud_exceptions.GoogleAPICallError):
    """Turn Google API errors into something a human can act on.

    A 403 here almost always means the Workload Identity chain is broken:
    either the KSA annotation is missing or the IAM binding does not match.
    """
    log.error("firestore call failed: %s", exc)
    return JSONResponse(
        status_code=502,
        content={
            "error": "datastore_unavailable",
            "detail": str(exc),
            "hint": (
                "A 403 usually means Workload Identity is misconfigured. Check the "
                "iam.gke.io/gcp-service-account annotation on the ServiceAccount and "
                "the roles/iam.workloadIdentityUser binding on the Google SA."
            ),
        },
    )


# --- health endpoints ------------------------------------------------------
# Two probes, two different questions:
#   /healthz  "is this process alive?"        -> liveness. NO dependencies.
#   /readyz   "can this process do its job?"  -> readiness. Checks Firestore.
#
# Putting a dependency check in the liveness probe is a classic outage
# generator: Firestore hiccups, every Pod fails liveness, Kubernetes restarts
# all of them at once, and you have turned a blip into a full outage.
@app.get("/healthz", tags=["health"])
def healthz() -> dict[str, str]:
    return {"status": "ok", "version": APP_VERSION}


@app.get("/readyz", tags=["health"])
def readyz() -> dict[str, str]:
    try:
        next(get_db().collection(COLLECTION).limit(1).stream(), None)
    except Exception as exc:  # noqa: BLE001 - we want the reason in the response
        log.warning("readiness check failed: %s", exc)
        raise HTTPException(status_code=503, detail=f"firestore unreachable: {exc}") from exc
    return {"status": "ready", "version": APP_VERSION}


@app.get("/api/version", tags=["health"])
def version() -> dict[str, str]:
    """The web tier displays this, which is how you prove a deploy landed."""
    return {"version": APP_VERSION, "pod": POD_NAME, "project": PROJECT_ID or "unset"}


# --- links -----------------------------------------------------------------
@app.post("/api/links", response_model=Link, status_code=201, tags=["links"])
def create_link(payload: CreateLinkRequest) -> Link:
    db = get_db()
    target = str(payload.target_url)

    # Random codes will occasionally collide. document.create() fails if the
    # document already exists, so we retry rather than silently overwriting
    # somebody else's link.
    for attempt in range(MAX_CODE_ATTEMPTS):
        code = "".join(random.choices(CODE_ALPHABET, k=CODE_LENGTH))
        doc_ref = db.collection(COLLECTION).document(code)
        record = {
            "target_url": target,
            "clicks": 0,
            "created_at": datetime.now(timezone.utc),
        }
        try:
            doc_ref.create(record)
        except gcloud_exceptions.AlreadyExists:
            log.info("code collision on %s, attempt %d", code, attempt + 1)
            continue
        log.info("created short code %s -> %s", code, target)
        return _to_link(code, record)

    raise HTTPException(status_code=500, detail="could not allocate a unique short code")


@app.get("/api/links", response_model=list[Link], tags=["links"])
def list_links() -> list[Link]:
    db = get_db()
    query = (
        db.collection(COLLECTION)
        .order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(LIST_LIMIT)
    )
    return [_to_link(doc.id, doc.to_dict() or {}) for doc in query.stream()]


# response_class=Response is required: a 204 carries no body, and FastAPI
# refuses to build a response model for it.
@app.delete("/api/links/{code}", status_code=204, response_class=Response, tags=["links"])
def delete_link(code: str) -> Response:
    get_db().collection(COLLECTION).document(code).delete()
    log.info("deleted short code %s", code)
    return Response(status_code=204)


@app.get("/r/{code}", tags=["links"])
def resolve(code: str) -> RedirectResponse:
    db = get_db()
    doc_ref = db.collection(COLLECTION).document(code)
    snapshot = doc_ref.get()
    if not snapshot.exists:
        raise HTTPException(status_code=404, detail=f"unknown short code: {code}")

    # firestore.Increment is applied server-side and atomically, so two
    # concurrent clicks cannot lose a count the way read-modify-write would.
    doc_ref.update({"clicks": firestore.Increment(1)})

    target = (snapshot.to_dict() or {}).get("target_url")
    if not target:
        raise HTTPException(status_code=500, detail="link record is missing target_url")

    log.info("redirect %s -> %s", code, target)
    return RedirectResponse(url=target, status_code=302)
```

**Four decisions in that file worth understanding.**

**1. The Firestore client is created lazily.** Building it at import time
means that if credentials are not ready, the process dies before it can serve
anything. In Kubernetes that shows up as `CrashLoopBackOff` with a stack trace
buried in logs. Lazy initialisation means the process starts, `/healthz`
answers, `/readyz` fails with a readable message, and `kubectl describe pod`
tells you exactly what is wrong.

**2. Endpoints are `def`, not `async def`.** The Firestore client is
synchronous. An `async def` endpoint that makes a blocking call stalls the
whole event loop and every other in-flight request with it. FastAPI runs plain
`def` endpoints in a thread pool, which is correct here.

**3. `firestore.Increment(1)` instead of read-modify-write.** Reading
`clicks`, adding one, and writing it back loses counts when two clicks land at
the same time. `Increment` is applied atomically on the server.

**4. Logs are JSON with a `severity` field.** Cloud Logging parses structured
JSON on stdout, so `severity` becomes a real, filterable log level in the
console instead of an unstructured line you have to grep. `"pod"` is in every
record too, which makes "which replica served this?" answerable. You will use
this in Chapter 11.

**Create `app/api/requirements.txt`:**

```text
# Pinned exactly. Unpinned dependencies mean a rebuild six months from now
# produces a different image from the same commit, which makes "it worked
# yesterday" impossible to debug.
fastapi==0.115.6
uvicorn[standard]==0.34.0
google-cloud-firestore==2.20.0
pydantic==2.10.4
```

**Why exact pins (`==`) and not ranges.** With `>=`, rebuilding this image in
six months from the same git commit produces a different image. Then "it
worked yesterday" becomes unanswerable, because the thing that changed is not
in your git history at all.

---

## Step 5.3 — The tests

**What we're doing.** Writing tests that run in about a second, need no GCP
project and no network — so Chapter 09's pipeline can run them on every pull
request.

**Create `app/api/requirements-dev.txt`:**

```text
# Test-only dependencies. Kept out of requirements.txt so they never ship
# inside the runtime image.
-r requirements.txt
pytest==8.3.4
httpx==0.28.1
```

**Create `app/api/test_main.py`:**

```python
"""Tests for the LinkForge API.

These run against an in-memory stand-in for Firestore, so they need no GCP
project, no credentials and no network. That is the point: the CI pipeline can
run them on every pull request in about a second, long before anything is
deployed.

    pip install -r requirements-dev.txt
    pytest -q
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from google.api_core import exceptions as gcloud_exceptions

os.environ.setdefault("APP_VERSION", "test")
os.environ.setdefault("POD_NAME", "test-pod")
os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "linkforge-test")

import main  # noqa: E402  (import after env setup, on purpose)


# ---------------------------------------------------------------------------
# A tiny fake Firestore: just the handful of calls main.py actually makes.
# ---------------------------------------------------------------------------
class FakeSnapshot:
    def __init__(self, doc_id: str, data: dict | None):
        self.id = doc_id
        self._data = data

    @property
    def exists(self) -> bool:
        return self._data is not None

    def to_dict(self) -> dict | None:
        return dict(self._data) if self._data is not None else None


class FakeDocRef:
    def __init__(self, store: dict, doc_id: str):
        self._store = store
        self.id = doc_id

    def create(self, data: dict) -> None:
        if self.id in self._store:
            raise gcloud_exceptions.AlreadyExists(self.id)
        self._store[self.id] = dict(data)

    def get(self) -> FakeSnapshot:
        return FakeSnapshot(self.id, self._store.get(self.id))

    def update(self, patch: dict) -> None:
        record = self._store[self.id]
        for key, value in patch.items():
            # Mimic firestore.Increment, which is applied server-side.
            if hasattr(value, "value") and not isinstance(value, (str, bytes)):
                record[key] = record.get(key, 0) + value.value
            else:
                record[key] = value

    def delete(self) -> None:
        self._store.pop(self.id, None)


class FakeQuery:
    def __init__(self, store: dict):
        self._store = store
        self._limit = None

    def order_by(self, field: str, direction=None) -> "FakeQuery":
        self._field = field
        self._descending = direction == main.firestore.Query.DESCENDING
        return self

    def limit(self, count: int) -> "FakeQuery":
        self._limit = count
        return self

    def stream(self):
        items = sorted(
            self._store.items(),
            key=lambda kv: kv[1].get("created_at", datetime.min.replace(tzinfo=timezone.utc)),
            reverse=getattr(self, "_descending", True),
        )
        if self._limit is not None:
            items = items[: self._limit]
        return (FakeSnapshot(doc_id, data) for doc_id, data in items)


class FakeCollection(FakeQuery):
    def document(self, doc_id: str) -> FakeDocRef:
        return FakeDocRef(self._store, doc_id)


class FakeClient:
    def __init__(self):
        self.store: dict[str, dict] = {}

    def collection(self, _name: str) -> FakeCollection:
        return FakeCollection(self.store)


@pytest.fixture()
def client(monkeypatch):
    fake = FakeClient()
    monkeypatch.setattr(main, "get_db", lambda: fake)
    test_client = TestClient(main.app)
    test_client.fake = fake
    return test_client


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------
def test_healthz_does_not_touch_the_database(monkeypatch):
    """Liveness must not depend on Firestore, or a Firestore blip restarts
    every Pod at once and turns a hiccup into an outage."""

    def explode():
        raise AssertionError("liveness probe must not call Firestore")

    monkeypatch.setattr(main, "get_db", explode)
    response = TestClient(main.app).get("/healthz")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_readyz_reports_unready_when_firestore_is_down(monkeypatch):
    def explode():
        raise RuntimeError("connection refused")

    monkeypatch.setattr(main, "get_db", explode)
    response = TestClient(main.app).get("/readyz")
    assert response.status_code == 503


def test_readyz_ok(client):
    assert client.get("/readyz").json()["status"] == "ready"


def test_version_reports_build_and_pod(client):
    body = client.get("/api/version").json()
    assert body["version"] == "test"
    assert body["pod"] == "test-pod"


# ---------------------------------------------------------------------------
# Links
# ---------------------------------------------------------------------------
def test_create_link_returns_a_code(client):
    response = client.post("/api/links", json={"target_url": "https://example.com/a"})
    assert response.status_code == 201
    body = response.json()
    assert len(body["code"]) == main.CODE_LENGTH
    assert body["clicks"] == 0
    assert body["short_path"] == f"/r/{body['code']}"
    assert body["target_url"] == "https://example.com/a"


def test_create_link_rejects_a_non_url(client):
    assert client.post("/api/links", json={"target_url": "not-a-url"}).status_code == 422


def test_create_link_rejects_a_javascript_url(client):
    """HttpUrl only accepts http/https, which closes an obvious XSS vector."""
    assert client.post("/api/links", json={"target_url": "javascript:alert(1)"}).status_code == 422


def test_create_link_retries_on_code_collision(client, monkeypatch):
    codes = iter(["aaaaaaa", "aaaaaaa", "bbbbbbb"])
    monkeypatch.setattr(main.random, "choices", lambda _alphabet, k: list(next(codes)))

    first = client.post("/api/links", json={"target_url": "https://example.com/1"})
    second = client.post("/api/links", json={"target_url": "https://example.com/2"})

    assert first.json()["code"] == "aaaaaaa"
    # The second attempt collided, retried, and landed on a free code instead
    # of silently overwriting the first link.
    assert second.json()["code"] == "bbbbbbb"
    assert client.fake.store["aaaaaaa"]["target_url"] == "https://example.com/1"


def test_list_links_is_newest_first(client):
    now = datetime.now(timezone.utc)
    client.fake.store.update({
        "older": {"target_url": "https://example.com/old", "clicks": 0, "created_at": now - timedelta(hours=1)},
        "newer": {"target_url": "https://example.com/new", "clicks": 0, "created_at": now},
    })
    codes = [item["code"] for item in client.get("/api/links").json()]
    assert codes == ["newer", "older"]


def test_redirect_sends_302_and_counts_the_click(client):
    code = client.post("/api/links", json={"target_url": "https://example.com/z"}).json()["code"]

    response = client.get(f"/r/{code}", follow_redirects=False)
    assert response.status_code == 302
    assert response.headers["location"] == "https://example.com/z"

    client.get(f"/r/{code}", follow_redirects=False)
    assert client.fake.store[code]["clicks"] == 2


def test_redirect_on_unknown_code_is_404(client):
    assert client.get("/r/nope123", follow_redirects=False).status_code == 404


def test_delete_link(client):
    code = client.post("/api/links", json={"target_url": "https://example.com/d"}).json()["code"]
    assert client.delete(f"/api/links/{code}").status_code == 204
    assert client.get(f"/r/{code}", follow_redirects=False).status_code == 404
```

**Run them.**

```bash
cd app/api
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
```

Expected:

```
............                                                             [100%]
12 passed in 0.6s
```

**What just happened.** Twelve tests ran against an in-memory stand-in for
Firestore. Notice what they cover: not just "does it return 200", but the
behaviours that are easy to break and expensive to break — that liveness does
not touch the database, that a code collision retries instead of silently
overwriting someone else's link, that clicks are counted atomically, and that
`javascript:` URLs are rejected.

> **A note on that last one.** A URL shortener that accepts any string is an
> open redirector, and open redirectors get used in phishing. Pydantic's
> `HttpUrl` only accepts `http` and `https`, which closes the obvious hole. A
> production shortener would go further: a domain blocklist, rate limiting, and
> an abuse-reporting path.

---

## Step 5.4 — The API container image

**Create `app/api/Dockerfile`:**

```dockerfile
# syntax=docker/dockerfile:1

FROM python:3.12-slim

# PYTHONDONTWRITEBYTECODE: no .pyc clutter in the image layer
# PYTHONUNBUFFERED: logs reach stdout immediately instead of sitting in a
#   buffer, which matters because Cloud Logging reads stdout
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app

# Copy requirements FIRST, install, THEN copy source. Docker caches layers, so
# editing main.py does not re-run pip install. This one ordering decision is
# the difference between a 5-second and a 90-second CI build.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py ./

# Run as a non-root, non-privileged user. Kubernetes will also enforce this
# via securityContext.runAsNonRoot, and the Pod will refuse to start if the
# image's default user is root.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
USER 10001

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

**Create `app/api/.dockerignore`:**

```text
__pycache__/
*.pyc
.venv/
.pytest_cache/
.env
```

**The two lines that matter most.**

**Layer ordering.** `COPY requirements.txt` → `RUN pip install` → `COPY
main.py`. Docker caches each layer and invalidates everything after the first
change. Because dependencies are copied and installed *before* the source,
editing `main.py` reuses the cached `pip install` layer. Reverse those two and
every one-character change re-downloads every dependency — the difference
between a 5-second and a 90-second CI build.

**`USER 10001`.** The container runs as an unprivileged user. Chapter 06's
Deployment also sets `runAsNonRoot: true`, and Kubernetes will refuse to start
a Pod whose image defaults to root. Building it in from the start avoids that
argument.

---

## Step 5.5 — The web tier

**What we're doing.** A static page served by nginx. No build step, no npm, no
bundler — deliberately, because a JavaScript toolchain is a whole separate
thing to debug and it teaches you nothing about GCP.

**Create `app/web/index.html`:**

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>LinkForge</title>
  <link rel="stylesheet" href="/styles.css" />
</head>
<body>
  <main class="shell">
    <header class="head">
      <h1>LinkForge</h1>
      <p class="sub">A very small URL shortener, running on GKE and Firestore.</p>
    </header>

    <section class="card">
      <form id="create-form" autocomplete="off">
        <label for="target">Long URL</label>
        <div class="row">
          <input id="target" name="target" type="url" required
                 placeholder="https://cloud.google.com/kubernetes-engine/docs" />
          <button type="submit" id="submit-btn">Shorten</button>
        </div>
        <p class="error" id="error" hidden></p>
      </form>
    </section>

    <section class="card">
      <div class="card-head">
        <h2>Recent links</h2>
        <button class="ghost" id="refresh-btn" type="button">Refresh</button>
      </div>
      <div id="links-wrap">
        <p class="muted" id="empty">Loading&hellip;</p>
        <table id="links" hidden>
          <thead>
            <tr>
              <th>Short link</th>
              <th>Target</th>
              <th class="num">Clicks</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="links-body"></tbody>
        </table>
      </div>
    </section>

    <!-- This footer is the payoff of the CI/CD chapter: it shows which build
         is serving you, and which Pod answered. Refresh to watch the Pod name
         change as the load balancer spreads requests across replicas. -->
    <footer class="foot">
      <span>api version <code id="version">?</code></span>
      <span>served by pod <code id="pod">?</code></span>
    </footer>
  </main>

  <script src="/app.js"></script>
</body>
</html>
```

**Create `app/web/styles.css`:**

```css
:root {
  --bg: #f6f7f9;
  --panel: #ffffff;
  --ink: #10161f;
  --muted: #5f6b7a;
  --line: #e3e7ec;
  --accent: #1a56db;
  --accent-ink: #ffffff;
  --danger: #b42318;
  --radius: 10px;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0e1116;
    --panel: #161b22;
    --ink: #e6edf3;
    --muted: #8b949e;
    --line: #262c36;
    --accent: #4c8dff;
    --accent-ink: #08111f;
    --danger: #ff7b72;
  }
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}

.shell { max-width: 820px; margin: 0 auto; padding: 40px 20px 64px; }

.head h1 { margin: 0 0 4px; font-size: 28px; letter-spacing: -0.02em; }
.sub { margin: 0 0 28px; color: var(--muted); }

.card {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 20px;
  margin-bottom: 20px;
}

.card-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
.card-head h2 { margin: 0; font-size: 16px; }

label { display: block; font-size: 13px; color: var(--muted); margin-bottom: 6px; }

.row { display: flex; gap: 10px; }

input[type="url"] {
  flex: 1;
  min-width: 0;
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg);
  color: var(--ink);
  font-size: 14px;
}
input[type="url"]:focus { outline: 2px solid var(--accent); outline-offset: 1px; }

button {
  padding: 10px 16px;
  border: 0;
  border-radius: 8px;
  background: var(--accent);
  color: var(--accent-ink);
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
}
button:disabled { opacity: 0.55; cursor: progress; }

button.ghost, button.link {
  background: transparent;
  color: var(--muted);
  border: 1px solid var(--line);
  font-weight: 500;
  padding: 6px 10px;
}
button.link { border: 0; padding: 4px 6px; }
button.link:hover { color: var(--ink); }
button.link.danger:hover { color: var(--danger); }

table { width: 100%; border-collapse: collapse; font-size: 14px; }
th, td { text-align: left; padding: 9px 8px; border-bottom: 1px solid var(--line); vertical-align: middle; }
th { font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); font-weight: 600; }
th.num, td.num { text-align: right; width: 70px; }
td.actions { width: 120px; text-align: right; white-space: nowrap; }

td.target { max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); }

a { color: var(--accent); text-decoration: none; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
a:hover { text-decoration: underline; }

.muted { color: var(--muted); font-size: 14px; }
.error { color: var(--danger); font-size: 13px; margin: 10px 0 0; }

.foot {
  display: flex;
  gap: 18px;
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--muted);
  padding-top: 4px;
}
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
```

**Create `app/web/app.js`:**

```javascript
// LinkForge web tier.
//
// Every request below is a RELATIVE path. That is deliberate: the Ingress
// serves the web tier and the API tier from the same hostname, routing /api
// and /r to the API Service and everything else here. Same origin means no
// CORS configuration, and no API hostname baked into the image at build time.

const $ = (id) => document.getElementById(id);

async function api(path, options) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) {
    let detail = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      detail = body.detail || body.error || detail;
    } catch (_) { /* response was not JSON */ }
    throw new Error(detail);
  }
  return res.status === 204 ? null : res.json();
}

function showError(message) {
  const el = $("error");
  if (!message) { el.hidden = true; return; }
  el.textContent = message;
  el.hidden = false;
}

function render(links) {
  const table = $("links");
  const empty = $("empty");
  const body = $("links-body");
  body.replaceChildren();

  if (!links.length) {
    empty.textContent = "No links yet. Shorten one above.";
    empty.hidden = false;
    table.hidden = true;
    return;
  }

  empty.hidden = true;
  table.hidden = false;

  for (const link of links) {
    const shortUrl = `${window.location.origin}${link.short_path}`;
    const tr = document.createElement("tr");

    const codeCell = document.createElement("td");
    const anchor = document.createElement("a");
    anchor.href = link.short_path;
    anchor.textContent = `/r/${link.code}`;
    anchor.target = "_blank";
    anchor.rel = "noopener";
    codeCell.append(anchor);

    const targetCell = document.createElement("td");
    targetCell.className = "target";
    targetCell.title = link.target_url;
    targetCell.textContent = link.target_url;

    const clicksCell = document.createElement("td");
    clicksCell.className = "num";
    clicksCell.textContent = link.clicks;

    const actions = document.createElement("td");
    actions.className = "actions";

    const copy = document.createElement("button");
    copy.className = "link";
    copy.type = "button";
    copy.textContent = "Copy";
    copy.addEventListener("click", async () => {
      await navigator.clipboard.writeText(shortUrl);
      copy.textContent = "Copied";
      setTimeout(() => { copy.textContent = "Copy"; }, 1200);
    });

    const del = document.createElement("button");
    del.className = "link danger";
    del.type = "button";
    del.textContent = "Delete";
    del.addEventListener("click", async () => {
      try {
        await api(`/api/links/${link.code}`, { method: "DELETE" });
        await load();
      } catch (err) { showError(err.message); }
    });

    actions.append(copy, del);
    tr.append(codeCell, targetCell, clicksCell, actions);
    body.append(tr);
  }
}

async function load() {
  try {
    render(await api("/api/links"));
    showError("");
  } catch (err) {
    $("empty").textContent = "Could not reach the API.";
    $("empty").hidden = false;
    showError(err.message);
  }
}

async function loadVersion() {
  try {
    const info = await api("/api/version");
    $("version").textContent = info.version;
    $("pod").textContent = info.pod;
  } catch (_) {
    $("version").textContent = "unreachable";
  }
}

$("create-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const btn = $("submit-btn");
  const input = $("target");
  btn.disabled = true;
  try {
    await api("/api/links", {
      method: "POST",
      body: JSON.stringify({ target_url: input.value }),
    });
    input.value = "";
    showError("");
    await load();
  } catch (err) {
    showError(err.message);
  } finally {
    btn.disabled = false;
  }
});

$("refresh-btn").addEventListener("click", () => { load(); loadVersion(); });

load();
loadVersion();
```

**The single most important thing in that JavaScript** is that every URL is
**relative**: `/api/links`, not `http://some-ip/api/links`. Because the Ingress
serves both tiers from one hostname, the browser sees one origin. That gives
you, for free:

- **No CORS.** Not "CORS configured correctly" — no CORS at all, because there
  is no cross-origin request.
- **No API address baked into the image.** The same web image works on your
  laptop, in staging and in production. If the API address were compiled in,
  you would need a different image per environment, which defeats the purpose
  of building an image once and promoting it.

**Create `app/web/nginx.conf`** (the production config):

```nginx
# PRODUCTION config. In the cluster, nginx serves static files and nothing
# else -- the Ingress is what routes /api and /r to the API Service, so those
# paths never reach this container.
server {
    listen       8080;
    server_name  _;
    root         /usr/share/nginx/html;
    index        index.html;

    # no-store matters more than you would think. Without it, you push a new
    # build in Chapter 10, the rollout succeeds, and your browser cheerfully
    # keeps showing you the old page -- and you spend an hour debugging a
    # deployment that actually worked.
    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-store, must-revalidate";
    }

    # Liveness/readiness target. access_log off keeps kubelet's probes from
    # drowning out real traffic in your logs.
    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }
}
```

**Create `app/web/nginx.local.conf`** (local development only):

```nginx
# LOCAL DEVELOPMENT ONLY -- mounted over the production config by
# docker-compose. It fakes what the Ingress does in the cluster: same origin,
# /api and /r proxied to the API container. That way the JavaScript is
# identical locally and in production.
server {
    listen       8080;
    server_name  _;
    root         /usr/share/nginx/html;
    index        index.html;

    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-store, must-revalidate";
    }

    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    location /api/ { proxy_pass http://api:8080; proxy_set_header Host $host; }
    location /r/   { proxy_pass http://api:8080; proxy_set_header Host $host; }
}
```

**Why two configs.** In the cluster, the Ingress routes `/api` and `/r` to the
API Service, so nginx never sees those paths and only needs to serve files.
Locally there is no Ingress, so the local config proxies those two paths to the
`api` container — reproducing same-origin behaviour so the JavaScript is
identical in both places.

**Create `app/web/Dockerfile`:**

```dockerfile
# syntax=docker/dockerfile:1

# nginx-unprivileged is the plain nginx image rebuilt to run as UID 101 and
# listen on 8080. The stock nginx image runs as root and writes to
# /var/run/nginx.pid, so it fails under runAsNonRoot + readOnlyRootFilesystem.
# Starting from the unprivileged variant avoids a pile of workarounds.
FROM nginxinc/nginx-unprivileged:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html app.js styles.css /usr/share/nginx/html/

EXPOSE 8080
```

**Create `app/web/.dockerignore`:**

```text
nginx.local.conf
```

**Why `nginx-unprivileged`.** The standard `nginx` image runs as root and
writes its PID to `/var/run/nginx.pid`. Under `runAsNonRoot` it fails to start,
and the workarounds are fiddly. `nginxinc/nginx-unprivileged` is the same nginx
rebuilt to run as UID 101 and listen on 8080. Starting from the right base
image is easier than fighting the wrong one.

---

## Step 5.6 — Run the whole thing locally

**What we're doing.** Bringing up all three tiers on your laptop, using the
official Firestore **emulator** so no real database is touched and nothing is
billed.

**Create `app/docker-compose.yml`:**

```yaml
# ---------------------------------------------------------------------------
# Local development stack -- no GCP account needed, no cost, works offline
# ---------------------------------------------------------------------------
#   docker compose -f app/docker-compose.yml up --build
#   open http://localhost:8080
#
# Three containers that mirror the three tiers:
#   firestore : the official Firestore EMULATOR, so no real database is touched
#   api       : the same image that runs in GKE
#   web       : the same image that runs in GKE, plus a proxy config that
#               stands in for the Ingress
services:
  firestore:
    image: google/cloud-sdk:emulators
    command: >
      gcloud emulators firestore start
      --host-port=0.0.0.0:8200
      --project=linkforge-local
    ports:
      - "8200:8200"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8200/ || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 20

  api:
    build:
      context: ./api
    environment:
      # The google-cloud-firestore client checks for this variable and, when
      # it is set, talks to the emulator and skips authentication entirely.
      FIRESTORE_EMULATOR_HOST: firestore:8200
      GOOGLE_CLOUD_PROJECT: linkforge-local
      APP_VERSION: local-dev
      POD_NAME: local-api
    ports:
      - "8000:8080"
    depends_on:
      firestore:
        condition: service_healthy

  web:
    build:
      context: ./web
    volumes:
      # Swap in the config that proxies /api and /r to the api container,
      # standing in for what the GKE Ingress does in the cluster.
      - ./web/nginx.local.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "8080:8080"
    depends_on:
      - api
```

**Do this.**

```bash
docker compose -f app/docker-compose.yml up --build
```

**What just happened.** Three containers started:

- `firestore` — the Firestore emulator on port 8200. The Python client library
  checks for the `FIRESTORE_EMULATOR_HOST` environment variable and, when it is
  set, talks to the emulator and **skips authentication entirely**. That is why
  this works with no GCP credentials.
- `api` — the exact image that will run in GKE.
- `web` — the exact image that will run in GKE, with the local nginx config
  mounted over the production one.

First build takes 1–2 minutes. The emulator image is large.

**Verify.** Open <http://localhost:8080> and:

1. Paste `https://cloud.google.com/kubernetes-engine/docs` into the box, press
   **Shorten**.
2. A row appears with a short link like `/r/k3f9x2p`.
3. Click it — you land on the Google docs page.
4. Press **Refresh** — the click count is `1`.
5. The footer reads `api version local-dev`, `served by pod local-api`.

Also check the auto-generated API documentation, which FastAPI gives you for
free: <http://localhost:8000/api/docs>

**Command-line check:**

```bash
curl -s localhost:8000/healthz
curl -s -X POST localhost:8000/api/links \
  -H 'Content-Type: application/json' \
  -d '{"target_url":"https://example.com"}'
curl -s localhost:8000/api/links
```

Expected:

```json
{"status":"ok","version":"local-dev"}
{"code":"k3f9x2p","target_url":"https://example.com/","clicks":0,"created_at":"2026-...","short_path":"/r/k3f9x2p"}
[{"code":"k3f9x2p",...}]
```

**Stop it** with `Ctrl-C`, then:

```bash
docker compose -f app/docker-compose.yml down
```

**If it breaks.**

- *`web` shows "Could not reach the API"* — the api container is not up.
  `docker compose -f app/docker-compose.yml logs api`.
- *`api` exits immediately* — usually a Python syntax error. The logs show the
  traceback.
- *Firestore emulator never becomes healthy* — the image is ~1 GB; give the
  first pull time. If it persists, check `docker compose logs firestore`.
- *Port 8080 already in use* — change the left-hand side of `"8080:8080"` in
  the compose file to something free.

---

> ✅ **Checkpoint** — LinkForge runs end to end on your laptop: you can create
> a short link, follow it, and watch the counter increment. Twelve tests pass.
> Both container images build. Nothing has been deployed and nothing new is
> being billed.

**Next:** [Chapter 06 — Build and deploy by hand](06-manual-build-and-deploy.md)
