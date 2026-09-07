import asyncio

import jwt
from fastapi import HTTPException, Request
from jwt import PyJWKClient

from app.config import Settings


class Authenticator:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.jwks = (
            None
            if settings.local_auth
            else PyJWKClient(
                f"{settings.issuer}/.well-known/jwks.json",
                cache_jwk_set=True,
                lifespan=3600,
                timeout=5,
            )
        )

    def verify(self, token: str) -> str:
        key = self.jwks.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            key.key,
            algorithms=["RS256"],
            issuer=self.settings.issuer,
            options={"verify_aud": False, "require": ["exp", "iat", "sub", "iss"]},
            leeway=30,
        )
        # Cognito access tokens use client_id; ID tokens use aud and are NOT API tokens.
        if claims.get("token_use") != "access":
            raise jwt.InvalidTokenError("Access token required")
        if claims.get("client_id") != self.settings.cognito_client_id:
            raise jwt.InvalidTokenError("Wrong OAuth client")
        if "openid" not in claims.get("scope", "").split():
            raise jwt.InvalidTokenError("Required scope missing")
        return claims["sub"]

    async def user(self, request: Request) -> str:
        if self.settings.local_auth:
            return "local-demo-user"
        header = request.headers.get("authorization", "")
        if not header.startswith("Bearer ") or len(header) > 16_384:
            raise HTTPException(401, "Sign in required", headers={"WWW-Authenticate": "Bearer"})
        try:
            return await asyncio.to_thread(self.verify, header[7:])
        except (jwt.PyJWTError, ValueError, OSError):
            raise HTTPException(
                401, "Invalid or expired access token", headers={"WWW-Authenticate": "Bearer"}
            ) from None
