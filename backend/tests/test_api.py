import asyncio
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


class BrokenProvider:
    async def events(self, history, text):
        yield {"type": "delta", "text": "partial"}
        raise RuntimeError("Private upstream failure details must never escape")


class SlowProvider:
    async def events(self, history, text):
        await asyncio.sleep(10)
        yield {"type": "delta", "text": "late"}


def test_stream_and_nonstream_saved_once(store):
    settings = Settings(local_auth=True, mock_claude=True)
    with TestClient(create_app(settings, store=store)) as client:
        cid = client.post("/api/conversations").json()["id"]
        body = {"message": "hello", "request_id": str(uuid4()), "stream": True}
        result = client.post(f"/api/conversations/{cid}/messages", json=body)
        assert result.status_code == 200
        assert "event: delta" in result.text and "event: done" in result.text
        body["stream"] = False
        repeat = client.post(f"/api/conversations/{cid}/messages", json=body)
        assert repeat.status_code == 200 and "hello" in repeat.json()["content"]
        assert len(client.get(f"/api/conversations/{cid}").json()["messages"]) == 2


@pytest.mark.parametrize("stream", [True, False])
def test_upstream_error_does_not_commit_partial_text(store, stream):
    settings = Settings(local_auth=True, mock_claude=True)
    with TestClient(create_app(settings, store=store, claude=BrokenProvider())) as client:
        cid = client.post("/api/conversations").json()["id"]
        body = {"message": "hello", "request_id": str(uuid4()), "stream": stream}
        result = client.post(f"/api/conversations/{cid}/messages", json=body)
        assert ("event: error" in result.text) if stream else result.status_code == 502
        assert "Private upstream" not in result.text
        assert client.get(f"/api/conversations/{cid}").json()["messages"] == []
        # Must not leave a stale lease after normal failure.
        assert client.post(f"/api/conversations/{cid}/messages", json=body).status_code != 409


def test_timeout_releases_lease(store):
    settings = Settings(local_auth=True, mock_claude=True, generation_timeout=1)
    with TestClient(create_app(settings, store=store, claude=SlowProvider())) as client:
        cid = client.post("/api/conversations").json()["id"]
        result = client.post(
            f"/api/conversations/{cid}/messages",
            json={"message": "hi", "request_id": str(uuid4()), "stream": False},
        )
        assert result.status_code == 504
        assert client.delete(f"/api/conversations/{cid}").status_code == 204


def test_request_limits_and_validation(store):
    with TestClient(create_app(Settings(local_auth=True, mock_claude=True), store=store)) as client:
        cid = client.post("/api/conversations").json()["id"]
        endpoint = f"/api/conversations/{cid}/messages"
        assert (
            client.post(endpoint, json={"message": "   ", "request_id": str(uuid4())}).status_code
            == 422
        )
        assert client.post(endpoint, content=b"x" * 40001).status_code == 413
        assert client.get("/api/conversations/not-a-uuid").status_code == 422


def test_aws_rejects_demo_auth():
    with pytest.raises(ValueError, match="forbidden on AWS"):
        Settings(app_env="prod", local_auth=True)


def test_auth_is_required_without_local_override():
    with TestClient(create_app(Settings(mock_claude=True))) as client:
        assert client.get("/api/conversations").status_code == 401
        assert client.get("/api/health/live").status_code == 200
