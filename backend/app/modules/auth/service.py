"""Sessions: signing in, refreshing, signing out, and checking access tokens.

- Access token: 15 minutes. Sent as ``Authorization: Bearer tp_at_...``.
- Refresh token: 30 days, single use. Refreshing revokes the session row
  ("rotated") and issues a new pair in the same family. If a rotated refresh
  token comes back, someone kept a copy: the whole family is revoked.
- Wrong passwords: the account locks after 5 in a row (users.service); one
  client address may fail 20 times in 15 minutes, across all usernames.
- Unknown usernames, wrong passwords and locked accounts all answer the same
  way and take the same time, so usernames cannot be probed.
"""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import Connection

from app.core import security
from app.core.ids import new_id
from app.core.ratelimit import FailureLimiter
from app.modules.users import service as users

from . import repo

ACCESS_LIFETIME = timedelta(minutes=15)
REFRESH_LIFETIME = timedelta(days=30)

ip_limiter = FailureLimiter(max_failures=20, window_s=15 * 60)


class AuthError(Exception):
    pass


class BadCredentials(AuthError):
    pass


class TooManyAttempts(AuthError):
    pass


class InvalidToken(AuthError):
    pass


@dataclass(frozen=True)
class Tokens:
    access_token: str
    access_expires_at: str
    refresh_token: str
    refresh_expires_at: str


@dataclass(frozen=True)
class Principal:
    """The signed-in person behind a request."""

    user_id: str
    tenant_id: str
    username: str
    display_name: str
    session_id: str
    family_id: str


def _now() -> datetime:
    return datetime.now(UTC)


def _issue(conn: Connection, user_id: str, tenant_id: str, family_id: str) -> tuple[Tokens, str]:
    """A new token pair in [family_id]; returns it with the new session's id."""
    now = _now()
    session_id = new_id()
    access = security.new_token(security.ACCESS_PREFIX)
    refresh = security.new_token(security.REFRESH_PREFIX)
    tokens = Tokens(
        access_token=access,
        access_expires_at=(now + ACCESS_LIFETIME).isoformat(),
        refresh_token=refresh,
        refresh_expires_at=(now + REFRESH_LIFETIME).isoformat(),
    )
    repo.insert(
        conn,
        {
            "id": session_id,
            "tenant_id": tenant_id,
            "user_id": user_id,
            "family_id": family_id,
            "access_hash": security.token_hash(access),
            "access_expires_at": tokens.access_expires_at,
            "refresh_hash": security.token_hash(refresh),
            "refresh_expires_at": tokens.refresh_expires_at,
            "created_at": now.isoformat(),
        },
    )
    return tokens, session_id


def login(
    conn: Connection, tenant_id: str, username: str, password: str, client: str
) -> tuple[Tokens, Principal]:
    if ip_limiter.blocked(client):
        raise TooManyAttempts()
    user = users.find(conn, tenant_id, username)
    if user is None:
        security.spend_password_time(password)
        ip_limiter.failed(client)
        raise BadCredentials()
    check = users.check_password(conn, user, password)
    conn.commit()  # keep the failure count even though we refuse
    if not check.ok:
        ip_limiter.failed(client)
        raise BadCredentials()
    family = new_id()
    tokens, session_id = _issue(conn, user["id"], user["tenant_id"], family)
    conn.commit()
    principal = Principal(
        user_id=user["id"],
        tenant_id=user["tenant_id"],
        username=user["username"],
        display_name=user["display_name"],
        session_id=session_id,
        family_id=family,
    )
    return tokens, principal


def refresh(conn: Connection, refresh_token: str) -> Tokens:
    if not refresh_token.startswith(security.REFRESH_PREFIX):
        raise InvalidToken()
    row = repo.by_refresh_hash(conn, security.token_hash(refresh_token))
    if row is None:
        raise InvalidToken()
    now = _now().isoformat()
    if row["revoked_at"] is not None:
        if row["revoked_reason"] == "rotated":
            # A spent refresh token came back: a copy exists. End the family.
            repo.revoke_family(conn, row["family_id"], "reuse_detected", now)
            conn.commit()
        raise InvalidToken()
    if row["refresh_expires_at"] <= now:
        raise InvalidToken()
    user = users.get(conn, row["user_id"])
    if user is None or user["status"] != "active":
        repo.revoke_family(conn, row["family_id"], "user_disabled", now)
        conn.commit()
        raise InvalidToken()
    if not repo.revoke_if_live(conn, row["id"], "rotated", now):
        # Another request rotated it a moment ago with the same token.
        repo.revoke_family(conn, row["family_id"], "reuse_detected", now)
        conn.commit()
        raise InvalidToken()
    tokens, _ = _issue(conn, user["id"], user["tenant_id"], row["family_id"])
    conn.commit()
    return tokens


def authenticate(conn: Connection, authorization: str | None) -> Principal:
    """The signed-in user behind an ``Authorization: Bearer tp_at_...`` header."""
    if not authorization or not authorization.startswith("Bearer "):
        raise InvalidToken()
    token = authorization.removeprefix("Bearer ").strip()
    if not token.startswith(security.ACCESS_PREFIX):
        raise InvalidToken()
    row = repo.by_access_hash(conn, security.token_hash(token))
    if row is None or row["revoked_at"] is not None:
        raise InvalidToken()
    if row["access_expires_at"] <= _now().isoformat():
        raise InvalidToken()
    user = users.get(conn, row["user_id"])
    if user is None or user["status"] != "active":
        raise InvalidToken()
    return Principal(
        user_id=user["id"],
        tenant_id=user["tenant_id"],
        username=user["username"],
        display_name=user["display_name"],
        session_id=row["id"],
        family_id=row["family_id"],
    )


def logout(conn: Connection, principal: Principal, everywhere: bool) -> None:
    now = _now().isoformat()
    if everywhere:
        repo.revoke_user(conn, principal.user_id, "logout_all", now)
    else:
        repo.revoke_family(conn, principal.family_id, "logout", now)
    conn.commit()


def change_password(
    conn: Connection, principal: Principal, current: str, new: str, client: str
) -> None:
    """Needs the current password. Signs out every other session."""
    if ip_limiter.blocked(client):
        raise TooManyAttempts()
    user = users.get(conn, principal.user_id)
    if user is None:
        raise InvalidToken()
    check = users.check_password(conn, user, current)
    conn.commit()
    if not check.ok:
        ip_limiter.failed(client)
        raise BadCredentials()
    user = users.get(conn, principal.user_id)
    if user is None:
        raise InvalidToken()
    users.change_password(conn, user, new)  # raises WeakPassword
    repo.revoke_user(
        conn,
        principal.user_id,
        "password_changed",
        _now().isoformat(),
        keep_family=principal.family_id,
    )
    conn.commit()
