"""Accounts: creating them, the password policy, and lockout bookkeeping.

The password policy follows NIST SP 800-63B: length matters, composition
rules ("one capital, one symbol") do not. A password must be 12-128
characters, not a well-known or patterned one, and not contain the username.
The upper limit stops very long inputs being used to make hashing expensive.

Callers own the transaction: nothing here commits.
"""

import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import Connection, RowMapping

from app.core import security
from app.core.ids import new_id

from . import repo

MIN_PASSWORD = 12
MAX_PASSWORD = 128
MAX_FAILED_LOGINS = 5
LOCKOUT = timedelta(minutes=15)

USERNAME = re.compile(r"^[a-z0-9][a-z0-9._@-]{2,63}$")

# Well-known passwords long enough to pass the length rule; checked
# case-insensitively after removing spaces.
_COMMON = frozenset(
    {
        "password1234",
        "password12345",
        "password123456",
        "passwordpassword",
        "123456789012",
        "1234567890123",
        "12345678901234",
        "123456123456",
        "qwertyuiopas",
        "qwerty123456",
        "qwertyqwerty",
        "1q2w3e4r5t6y",
        "1qaz2wsx3edc",
        "iloveyou1234",
        "abcdefghijkl",
        "abc123abc123",
        "letmein12345",
        "welcome12345",
        "changeme1234",
        "administrator",
        "admin1234567",
        "trustpunch123",
        "trustpunch1234",
        "p@ssw0rd1234",
    }
)


class UserError(Exception):
    pass


class WeakPassword(UserError):
    def __init__(self, reasons: list[str]) -> None:
        super().__init__("; ".join(reasons))
        self.reasons = reasons


class InvalidUsername(UserError):
    pass


class UsernameTaken(UserError):
    pass


@dataclass(frozen=True)
class LoginCheck:
    """Outcome of checking a password for a known user."""

    ok: bool
    locked: bool


def now_iso() -> str:
    return datetime.now(UTC).isoformat()


def normalise_username(username: str) -> str:
    return username.strip().lower()


def _is_sequence(text: str) -> bool:
    """abcdef..., fedcba..., 1234567890123... (digits wrap 9 -> 0) and reverse."""
    if len(text) < 3:
        return False
    pairs = list(zip(text, text[1:], strict=False))
    if text.isdigit():
        return {(int(b) - int(a)) % 10 for a, b in pairs} in ({1}, {9})
    return {ord(b) - ord(a) for a, b in pairs} in ({1}, {-1})


def password_problems(password: str, username: str = "") -> list[str]:
    """Why [password] is not acceptable (empty when it is)."""
    problems: list[str] = []
    if len(password) < MIN_PASSWORD:
        problems.append(f"use at least {MIN_PASSWORD} characters")
    if len(password) > MAX_PASSWORD:
        problems.append(f"use at most {MAX_PASSWORD} characters")
    folded = "".join(password.lower().split())
    if folded in _COMMON:
        problems.append("this password is too common")
    if folded and len(set(folded)) == 1:
        problems.append("do not repeat one character")
    elif _is_sequence(folded):
        problems.append("do not use a simple sequence")
    name = normalise_username(username)
    if len(name) >= 3 and name in password.lower():
        problems.append("do not include your username")
    return problems


def create_user(
    conn: Connection,
    tenant_id: str,
    username: str,
    display_name: str,
    password: str,
    email: str | None = None,
) -> str:
    name = normalise_username(username)
    if not USERNAME.match(name):
        raise InvalidUsername(
            "usernames are 3-64 characters: letters, digits and . _ @ - (start with a letter or digit)"
        )
    problems = password_problems(password, name)
    if problems:
        raise WeakPassword(problems)
    if repo.by_username(conn, tenant_id, name) is not None:
        raise UsernameTaken(name)
    now = now_iso()
    user_id = new_id()
    repo.insert(
        conn,
        {
            "id": user_id,
            "tenant_id": tenant_id,
            "username": name,
            "display_name": display_name.strip() or name,
            "email": email,
            "password_hash": security.hash_password(password),
            "password_changed_at": now,
            "created_at": now,
            "updated_at": now,
        },
    )
    return user_id


def find(conn: Connection, tenant_id: str, username: str) -> RowMapping | None:
    return repo.by_username(conn, tenant_id, normalise_username(username))


def get(conn: Connection, user_id: str) -> RowMapping | None:
    return repo.by_id(conn, user_id)


def is_locked(user: RowMapping, now: str) -> bool:
    return bool(user["locked_until"]) and user["locked_until"] > now


def check_password(conn: Connection, user: RowMapping, password: str) -> LoginCheck:
    """Checks [password] for [user] and records the outcome (no commit).

    A locked or disabled account always fails, at the same cost as a real
    check. The fifth wrong password in a row locks the account for LOCKOUT.
    """
    now = now_iso()
    if user["status"] != "active" or is_locked(user, now):
        security.spend_password_time(password)
        return LoginCheck(ok=False, locked=is_locked(user, now))
    if not security.verify_password(user["password_hash"], password):
        until = (datetime.now(UTC) + LOCKOUT).isoformat()
        repo.record_failure(conn, user["id"], MAX_FAILED_LOGINS, until, now)
        return LoginCheck(ok=False, locked=user["failed_logins"] + 1 >= MAX_FAILED_LOGINS)
    rehash = (
        security.hash_password(password) if security.needs_rehash(user["password_hash"]) else None
    )
    repo.record_success(conn, user["id"], now, rehash)
    return LoginCheck(ok=True, locked=False)


def change_password(conn: Connection, user: RowMapping, new_password: str) -> None:
    problems = password_problems(new_password, user["username"])
    if security.verify_password(user["password_hash"], new_password):
        problems.append("choose a password different from the current one")
    if problems:
        raise WeakPassword(problems)
    repo.set_password(conn, user["id"], security.hash_password(new_password), now_iso())


def set_disabled(conn: Connection, user_id: str, disabled: bool) -> bool:
    return repo.set_status(conn, user_id, "disabled" if disabled else "active", now_iso()) > 0
