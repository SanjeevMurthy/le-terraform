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
