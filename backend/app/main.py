import asyncio
import json
import logging
import time
from contextlib import asynccontextmanager
from uuid import UUID, uuid4

import anthropic
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field, field_validator

from app.auth import Authenticator
from app.claude import Claude
from app.config import Settings
from app.store import Store, public

log = logging.getLogger("platform")
logging.basicConfig(level=logging.INFO, format="%(message)s")
# Do not log prompt content, Authorization headers, or upstream request bodies.
logging.getLogger("httpx").setLevel(logging.WARNING)


class ChatInput(BaseModel):
    request_id: UUID
    message: str = Field(min_length=1, max_length=8000)
    stream: bool = True

    @field_validator("message")
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError("Message cannot be blank")
        return value


def frame(kind, data):
    return f"event: {kind}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


class BodyLimit:
    """Bound ASGI body bytes, including chunked uploads, before JSON parsing."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] not in {"POST", "PUT", "PATCH"}:
            return await self.app(scope, receive, send)
        chunks, size = [], 0
        while True:
            chunk = await receive()
            if chunk["type"] == "http.disconnect":
                return
            size += len(chunk.get("body", b""))
            if size > 40_000:
                return await JSONResponse({"detail": "Request body too large"}, 413)(
                    scope, receive, send
                )
            chunks.append(chunk)
            if not chunk.get("more_body", False):
                break

        async def replay():
            return chunks.pop(0) if chunks else await receive()

        await self.app(scope, replay, send)


def create_app(settings=None, store=None, claude=None, auth=None):
    settings = settings or Settings()
    storage = store or Store(settings)
    provider = claude or Claude(settings)
    authenticator = auth or Authenticator(settings)

    @asynccontextmanager
    async def lifespan(app):
        if not settings.mock_claude:
            await (
                provider.key()
            )  # Fail startup before accepting traffic if credentials are missing.
        yield

    app = FastAPI(
        title="Claude AWS DevOps Platform",
        version="1.0.0",
        lifespan=lifespan,
        docs_url="/api/docs" if settings.app_env == "local" else None,
        openapi_url="/api/openapi.json" if settings.app_env == "local" else None,
        redoc_url=None,
    )
    app.add_middleware(BodyLimit)

    @app.middleware("http")
    async def request_metadata(request, call_next):
        request.state.request_id = str(uuid4())
        started = time.monotonic()
        response = await call_next(request)
        response.headers["X-Request-ID"] = request.state.request_id
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store"
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        log.info(
            json.dumps(
                {
                    "event": "http",
                    "request_id": request.state.request_id,
                    "method": request.method,
                    "status": response.status_code,
                    "headers_ms": round((time.monotonic() - started) * 1000),
                }
            )
        )
        return response

    @app.exception_handler(Exception)
    async def unexpected(request, exc):
        log.error(
            json.dumps(
                {
                    "event": "internal_error",
                    "error_type": type(exc).__name__,
                    "request_id": getattr(request.state, "request_id", "unknown"),
                }
            )
        )
        return JSONResponse({"detail": "Service unavailable; try again later"}, status_code=503)

    async def user(request):
        sub = await authenticator.user(request)
        await asyncio.to_thread(storage.rate_limit, sub, "api", settings.api_requests_per_minute)
        return sub

    @app.get("/api/health/live")
    async def health():
        return {"status": "ok", "release": settings.release_sha}

    @app.get("/api/config")
    async def config():
        return {
            "localAuth": settings.local_auth,
            "mockClaude": settings.mock_claude,
            "authority": settings.issuer,
            "clientId": settings.cognito_client_id,
            "domain": settings.cognito_domain,
        }

    @app.post("/api/conversations", status_code=201)
    async def new_conversation(request: Request):
        return await asyncio.to_thread(storage.create, await user(request))

    @app.get("/api/conversations")
    async def conversations(request: Request, cursor: UUID | None = None):
        return await asyncio.to_thread(
            storage.list, await user(request), str(cursor) if cursor else None
        )

    @app.get("/api/conversations/{cid}")
    async def conversation(cid: UUID, request: Request):
        return public(await asyncio.to_thread(storage.get, await user(request), str(cid)), True)

    @app.delete("/api/conversations/{cid}", status_code=204)
    async def delete_conversation(cid: UUID, request: Request):
        await asyncio.to_thread(storage.delete, await user(request), str(cid))
        return Response(status_code=204)

    @app.post("/api/conversations/{cid}/messages")
    async def chat(cid: UUID, body: ChatInput, request: Request):
        sub, conversation_id = await user(request), str(cid)
        await asyncio.to_thread(storage.rate_limit, sub, "chat", settings.chat_requests_per_minute)
        lease, history, cached = await asyncio.to_thread(
            storage.begin, sub, conversation_id, str(body.request_id), body.message
        )
        if cached:
            if body.stream:
                return StreamingResponse(
                    iter([frame("delta", {"text": cached["content"]}), frame("done", cached)]),
                    media_type="text/event-stream",
                )
            return cached

        async def generate(queue):
            text, result = "", None
            try:
                async with asyncio.timeout(
                    settings.generation_timeout
                    if body.stream
                    else min(45, settings.generation_timeout)
                ):
                    async for event in provider.events(history, body.message):
                        if event["type"] == "delta":
                            text += event["text"]
                            if len(text.encode()) > 100_000:
                                raise ValueError("Response exceeds storage budget")
                            await queue.put(("delta", {"text": event["text"]}))
                        else:
                            result = event
                    if result is None:
                        raise RuntimeError("Upstream stream ended without a final message")
                    saved = await asyncio.to_thread(
                        storage.complete,
                        sub,
                        conversation_id,
                        lease,
                        history,
                        str(body.request_id),
                        body.message,
                        text,
                        result["stop_reason"],
                        result["usage"],
                    )
                    await queue.put(("done", saved))
                    log.info(
                        json.dumps(
                            {
                                "event": "chat_complete",
                                "usage": result["usage"],
                                "request_id": request.state.request_id,
                            }
                        )
                    )
            except Exception as exc:
                status = 429 if isinstance(exc, anthropic.RateLimitError) else 502
                if isinstance(exc, TimeoutError):
                    status = 504
                log.warning(
                    json.dumps(
                        {
                            "event": "chat_error",
                            "error_type": type(exc).__name__,
                            "request_id": request.state.request_id,
                        }
                    )
                )
                await queue.put(
                    (
                        "error",
                        {
                            "message": "Reply interrupted; please retry.",
                            "status": status,
                            "request_id": request.state.request_id,
                        },
                    )
                )
            finally:
                try:
                    await asyncio.shield(
                        asyncio.to_thread(storage.release, sub, conversation_id, lease)
                    )
                except Exception:
                    log.error(json.dumps({"event": "lease_release_failed"}))

        async def events():
            queue = asyncio.Queue(maxsize=64)
            worker = asyncio.create_task(generate(queue))
            try:
                while True:
                    try:
                        event, data = await asyncio.wait_for(queue.get(), timeout=10)
                    except TimeoutError:
                        yield ": keep-alive\n\n"
                        continue
                    yield frame(event, data)
                    if event in {"done", "error"}:
                        break
            finally:
                worker.cancel()
                try:
                    await worker
                except asyncio.CancelledError:
                    pass

        if body.stream:
            return StreamingResponse(
                events(),
                media_type="text/event-stream",
                headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
            )
        # Consume the same generation path to keep persistence/error behavior identical.
        async for event in events():
            if event.startswith("event: done"):
                return json.loads(event.split("data: ", 1)[1])
            if event.startswith("event: error"):
                detail = json.loads(event.split("data: ", 1)[1])
                raise HTTPException(detail["status"], detail["message"])
        raise HTTPException(502, "Reply interrupted")

    return app


app = create_app()
