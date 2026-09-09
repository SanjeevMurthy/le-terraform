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
