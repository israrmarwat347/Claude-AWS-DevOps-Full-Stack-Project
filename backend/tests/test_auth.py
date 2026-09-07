import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app.auth import Authenticator
from app.config import Settings


@pytest.fixture
def auth():
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    settings = Settings(cognito_user_pool_id="eu-west-1_test", cognito_client_id="client")
    verifier = Authenticator(settings)
    verifier.jwks = SimpleNamespace(
        get_signing_key_from_jwt=lambda _: SimpleNamespace(key=private.public_key())
    )
    claims = {
        "sub": "alice",
        "iss": settings.issuer,
        "client_id": "client",
        "token_use": "access",
        "scope": "openid email",
        "exp": int(time.time()) + 60,
        "iat": int(time.time()),
    }
    return verifier, private, claims


def test_valid_access_token(auth):
    verifier, private, claims = auth
    assert verifier.verify(jwt.encode(claims, private, algorithm="RS256")) == "alice"


@pytest.mark.parametrize(
    "field,value",
    [
        ("token_use", "id"),
        ("client_id", "other"),
        ("iss", "https://attacker.invalid"),
        ("scope", "email"),
        ("exp", 1),
    ],
)
def test_invalid_token_claims(auth, field, value):
    verifier, private, claims = auth
    claims[field] = value
    with pytest.raises(jwt.PyJWTError):
        verifier.verify(jwt.encode(claims, private, algorithm="RS256"))


def test_rejects_forged_signature(auth):
    verifier, _, claims = auth
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    with pytest.raises(jwt.PyJWTError):
        verifier.verify(jwt.encode(claims, other, algorithm="RS256"))
