import asyncio
import json
import time

import anthropic
import boto3
from botocore.config import Config

from app.config import Settings


class Claude:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.cached_key = ""
        self.cached_at = 0.0
        self.key_lock = asyncio.Lock()
        self.secrets = (
            boto3.client(
                "secretsmanager",
                region_name=settings.aws_region,
                config=Config(
                    connect_timeout=3,
                    read_timeout=5,
                    retries={"mode": "standard", "max_attempts": 3},
                ),
            )
            if settings.anthropic_secret_arn
            else None
        )

    async def key(self):
        if not self.secrets:
            key = self.settings.anthropic_api_key.get_secret_value()
            if not key:
                raise RuntimeError("Anthropic credential is missing")
            return key
        async with self.key_lock:
            if time.monotonic() - self.cached_at > 300 or not self.cached_key:
                result = await asyncio.to_thread(
                    self.secrets.get_secret_value, SecretId=self.settings.anthropic_secret_arn
                )
                self.cached_key = json.loads(result["SecretString"])["ANTHROPIC_API_KEY"]
                self.cached_at = time.monotonic()
            return self.cached_key

    async def events(self, history, text):
        if self.settings.mock_claude:
            reply = (
                "Local demo reply: "
                + text
                + "\n\nConnect your Claude API key to get real AI responses."
            )
            for word in reply.split(" "):
                await asyncio.sleep(0.01)
                yield {"type": "delta", "text": word + " "}
            yield {
                "type": "result",
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 0, "output_tokens": 0},
            }
            return
        messages = [{"role": m["role"], "content": m["content"]} for m in history]
        messages.append({"role": "user", "content": text})
        # SDK retries transient connection/408/409/429/5xx failures twice with backoff.
        # Once a response stream starts it is never replayed, avoiding duplicate output.
        async with anthropic.AsyncAnthropic(
            api_key=await self.key(),
            max_retries=2,
            timeout=45.0,
        ) as client:
            async with client.messages.stream(
                model=self.settings.claude_model,
                max_tokens=self.settings.max_output_tokens,
                system="You are a helpful assistant. Explain clearly and admit uncertainty.",
                messages=messages,
            ) as stream:
                async for text_delta in stream.text_stream:
                    yield {"type": "delta", "text": text_delta}
                message = await stream.get_final_message()
                yield {
                    "type": "result",
                    "stop_reason": message.stop_reason,
                    "usage": {
                        "input_tokens": message.usage.input_tokens,
                        "output_tokens": message.usage.output_tokens,
                    },
                }
