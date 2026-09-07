import json

import anthropic
import boto3
import httpx2
from moto import mock_aws

from app.claude import Claude
from app.config import Settings


async def test_sdk_messages_endpoint_retries_then_streams(monkeypatch):
    requests = []
    frames = [
        (
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": "msg_test",
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": "claude-haiku-4-5-20251001",
                    "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 5, "output_tokens": 0},
                },
            },
        ),
        (
            "content_block_start",
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""},
            },
        ),
        (
            "content_block_delta",
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "Hello"},
            },
        ),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        (
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 2},
            },
        ),
        ("message_stop", {"type": "message_stop"}),
    ]

    def handle(request):
        requests.append(request)
        if len(requests) == 1:
            return httpx2.Response(
                429,
                headers={"retry-after": "0"},
                json={"type": "error", "error": {"type": "rate_limit_error", "message": "busy"}},
            )
        return httpx2.Response(
            200,
            headers={"content-type": "text/event-stream"},
            content="".join(
                f"event: {kind}\ndata: {json.dumps(data)}\n\n" for kind, data in frames
            ),
        )

    constructor = anthropic.AsyncAnthropic

    def client(**kwargs):
        return constructor(
            **kwargs, http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(handle))
        )

    monkeypatch.setattr(anthropic, "AsyncAnthropic", client)
    provider = Claude(Settings(anthropic_api_key="unit-test-placeholder"))
    events = [event async for event in provider.events([], "hi")]
    assert len(requests) == 2
    assert requests[0].url.path == "/v1/messages"
    assert requests[0].headers["x-api-key"] == "unit-test-placeholder"
    assert json.loads(requests[0].content)["stream"] is True
    assert events[0] == {"type": "delta", "text": "Hello"}
    assert events[-1]["usage"] == {"input_tokens": 5, "output_tokens": 2}


async def test_secrets_manager_key_is_cached_and_refreshed(monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    with mock_aws():
        secrets = boto3.client("secretsmanager", region_name="eu-west-1")
        result = secrets.create_secret(
            Name="test/anthropic",
            SecretString=json.dumps({"ANTHROPIC_API_KEY": "first-test-value"}),
        )
        provider = Claude(Settings(anthropic_secret_arn=result["ARN"]))
        assert await provider.key() == "first-test-value"
        secrets.put_secret_value(
            SecretId=result["ARN"],
            SecretString=json.dumps({"ANTHROPIC_API_KEY": "second-test-value"}),
        )
        assert await provider.key() == "first-test-value"
        provider.cached_at = 0
        assert await provider.key() == "second-test-value"
