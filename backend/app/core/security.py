"""Passwords and opaque tokens.

Passwords: argon2id with the library's defaults (RFC 9106 second recommended
profile: 64 MiB memory, 3 passes, 4 lanes). Stored hashes carry their own
parameters, so raising the cost later only needs `needs_rehash()` at login.

Tokens: 256 random bits, URL-safe, with a short prefix (``tp_at_`` access,
``tp_rt_`` refresh) so a leaked token is recognisable to secret scanners and
can never be confused with a device token. The server stores SHA-256 only:
a copy of the database does not let anyone sign in.
"""

import hashlib
import secrets
from functools import cache

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

ACCESS_PREFIX = "tp_at_"
REFRESH_PREFIX = "tp_rt_"

_hasher = PasswordHasher()


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(stored_hash: str, password: str) -> bool:
    try:
        return _hasher.verify(stored_hash, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def needs_rehash(stored_hash: str) -> bool:
    try:
        return _hasher.check_needs_rehash(stored_hash)
    except InvalidHashError:
        return True


@cache
def _decoy_hash() -> str:
    return _hasher.hash(secrets.token_urlsafe(16))


def spend_password_time(password: str) -> None:
    """Costs what a real check costs, so an unknown username or a locked
    account answers as slowly as a wrong password (no username probing)."""
    verify_password(_decoy_hash(), password)


def new_token(prefix: str) -> str:
    return prefix + secrets.token_urlsafe(32)


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()
