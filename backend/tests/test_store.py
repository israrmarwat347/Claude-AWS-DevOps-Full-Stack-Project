from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.store import public


def test_tenant_isolation(store):
    c = store.create("alice")
    with pytest.raises(HTTPException) as exc:
        store.get("bob", c["id"])
    assert exc.value.status_code == 404
    assert store.list("bob")["items"] == []


def test_concurrent_lease_and_idempotency(store):
    cid = store.create("alice")["id"]
    rid = str(uuid4())
    lease, history, cached = store.begin("alice", cid, rid, "hello")
    assert cached is None
    with pytest.raises(HTTPException) as exc:
        store.begin("alice", cid, str(uuid4()), "second")
    assert exc.value.status_code == 409
    store.complete("alice", cid, lease, history, rid, "hello", "Hi", "end_turn", {})
    lease, history, cached = store.begin("alice", cid, rid, "hello")
    assert lease is None and cached["content"] == "Hi"
    assert len(public(store.get("alice", cid), True)["messages"]) == 2
    with pytest.raises(HTTPException) as exc:
        store.begin("alice", cid, rid, "different")
    assert exc.value.status_code == 409
    # Rejected duplicate must release the lease.
    next_lease, _, _ = store.begin("alice", cid, str(uuid4()), "next")
    assert next_lease


def test_failed_generation_release_preserves_history(store):
    cid = store.create("alice")["id"]
    lease, _, _ = store.begin("alice", cid, str(uuid4()), "hello")
    store.release("alice", cid, "wrong-owner")
    with pytest.raises(HTTPException):
        store.begin("alice", cid, str(uuid4()), "hello")
    store.release("alice", cid, lease)
    assert public(store.get("alice", cid), True)["messages"] == []
    assert store.begin("alice", cid, str(uuid4()), "hello")[0]


def test_distributed_rate_limit(store):
    store.rate_limit("alice", "chat", 1)
    with pytest.raises(HTTPException) as exc:
        store.rate_limit("alice", "chat", 1)
    assert exc.value.status_code == 429
    store.rate_limit("bob", "chat", 1)


def test_deletion_cannot_race_active_generation(store):
    cid = store.create("alice")["id"]
    lease, _, _ = store.begin("alice", cid, str(uuid4()), "hello")
    with pytest.raises(HTTPException) as exc:
        store.delete("alice", cid)
    assert exc.value.status_code == 409
    store.release("alice", cid, lease)
    store.delete("alice", cid)
    with pytest.raises(HTTPException):
        store.get("alice", cid)


def test_pagination(store):
    ids = {store.create("alice")["id"] for _ in range(53)}
    page = store.list("alice")
    assert len(page["items"]) == 50 and page["cursor"]
    page2 = store.list("alice", page["cursor"])
    assert {c["id"] for c in page["items"] + page2["items"]} == ids
    assert page2["cursor"] is None


def test_expired_items_not_exposed_while_waiting_for_ttl(store, monkeypatch):
    cid = store.create("alice")["id"]
    import app.store as module

    old = module.now()
    monkeypatch.setattr(module, "now", lambda: old + 31 * 86400)
    assert store.list("alice")["items"] == []
    with pytest.raises(HTTPException) as exc:
        store.get("alice", cid)
    assert exc.value.status_code == 404
