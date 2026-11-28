"""Phone pairing and device tokens.

A phone pairs once with a 6-digit code that only the server's operator can
see (``python -m app.cli pair-code``, also printed by ``run-dev.sh``). It gets
a long random token back; the server keeps only the token's SHA-256, so a
copy of the database does not let anyone act as a phone.

Guessing is limited three ways: a code lasts 10 minutes and works once;
every wrong guess counts against all open codes, which close after 5; and
one address may make only 5 wrong guesses per 10 minutes.
"""

import hashlib
import secrets
import sqlite3
import time
import uuid
from collections import defaultdict, deque
from datetime import UTC, datetime, timedelta

from . import repo

CODE_LIFETIME = timedelta(minutes=10)
MAX_FAILED_PER_CODE = 5
MAX_FAILED_PER_CLIENT = 5
CLIENT_WINDOW_S = 600


def _now() -> datetime:
    return datetime.now(UTC)


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def new_pair_code(conn: sqlite3.Connection) -> str:
    """A fresh 6-digit code, open for [CODE_LIFETIME]."""
    code = f"{secrets.randbelow(1_000_000):06d}"
    now = _now()
    repo.insert_pair_code(conn, _hash(code), now.isoformat(), (now + CODE_LIFETIME).isoformat())
    return code


class _ClientLimiter:
    """Wrong guesses per client address, in memory (resets on restart)."""

    def __init__(self) -> None:
        self._failures: dict[str, deque[float]] = defaultdict(deque)

    def _trim(self, client: str) -> deque[float]:
        q = self._failures[client]
        while q and q[0] < time.monotonic() - CLIENT_WINDOW_S:
            q.popleft()
        return q

    def blocked(self, client: str) -> bool:
        return len(self._trim(client)) >= MAX_FAILED_PER_CLIENT

    def failed(self, client: str) -> None:
        self._trim(client).append(time.monotonic())

    def reset(self) -> None:
        self._failures.clear()


limiter = _ClientLimiter()


class PairingRefused(Exception):
    pass


class TooManyAttempts(Exception):
    pass


class NotPaired(Exception):
    pass


class Blocked(Exception):
    pass


def pair_device(
    conn: sqlite3.Connection, code: str, name: str, platform: str, client: str
) -> tuple[str, str]:
    """Trades a valid open code for a new device id and token."""
    if limiter.blocked(client):
        raise TooManyAttempts()
    now = _now().isoformat()
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = repo.find_open_code(conn, _hash(code), now, MAX_FAILED_PER_CODE)
        if row is None:
            # Counts against every open code, so guessing closes them all.
            repo.count_failure_on_open_codes(conn, now)
            conn.execute("COMMIT")
            limiter.failed(client)
            raise PairingRefused()

        device_id = str(uuid.uuid4())
        token = secrets.token_urlsafe(32)
        repo.mark_code_used(conn, row["code_hash"], now)
        repo.insert_device(conn, device_id, name, platform, _hash(token), now)
        conn.execute("COMMIT")
        return device_id, token
    except PairingRefused:
        raise
    except Exception:
        conn.execute("ROLLBACK")
        raise


def device_for_token(conn: sqlite3.Connection, token: str) -> sqlite3.Row | None:
    return repo.by_token_hash(conn, _hash(token))


def authenticate(conn: sqlite3.Connection, authorization: str | None) -> sqlite3.Row:
    """The paired, unblocked device behind an ``Authorization: Bearer`` header."""
    if not authorization or not authorization.startswith("Bearer "):
        raise NotPaired()
    device = device_for_token(conn, authorization.removeprefix("Bearer ").strip())
    if device is None:
        raise NotPaired()
    if device["blocked"]:
        raise Blocked()
    repo.touch(conn, device["id"], _now().isoformat())
    return device


def list_devices(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return repo.all_devices(conn)


def set_blocked(conn: sqlite3.Connection, device_id: str, blocked: bool) -> bool:
    return repo.set_blocked(conn, device_id, blocked) > 0
