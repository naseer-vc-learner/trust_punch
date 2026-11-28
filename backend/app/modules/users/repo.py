"""SQL for users (SQLAlchemy Core, portable to PostgreSQL)."""

from typing import Any

import sqlalchemy as sa
from sqlalchemy import Connection, RowMapping

from .models import users


def insert(conn: Connection, values: dict[str, Any]) -> None:
    conn.execute(sa.insert(users).values(**values))


def by_username(conn: Connection, tenant_id: str, username: str) -> RowMapping | None:
    return (
        conn.execute(
            sa.select(users).where(users.c.tenant_id == tenant_id, users.c.username == username)
        )
        .mappings()
        .first()
    )


def by_id(conn: Connection, user_id: str) -> RowMapping | None:
    return conn.execute(sa.select(users).where(users.c.id == user_id)).mappings().first()


def record_failure(
    conn: Connection, user_id: str, max_failures: int, lock_until: str, now: str
) -> None:
    """One more wrong password. The database itself decides whether this one
    reaches [max_failures] and locks until [lock_until], so two wrong
    passwords arriving at once cannot both slip under the limit."""
    conn.execute(
        sa.update(users)
        .where(users.c.id == user_id)
        .values(
            failed_logins=users.c.failed_logins + 1,
            locked_until=sa.case(
                (users.c.failed_logins + 1 >= max_failures, lock_until),
                else_=users.c.locked_until,
            ),
            updated_at=now,
        )
    )


def record_success(conn: Connection, user_id: str, now: str, new_hash: str | None) -> None:
    values: dict[str, Any] = {
        "failed_logins": 0,
        "locked_until": None,
        "last_login_at": now,
        "updated_at": now,
    }
    if new_hash is not None:
        values["password_hash"] = new_hash
    conn.execute(sa.update(users).where(users.c.id == user_id).values(**values))


def set_password(conn: Connection, user_id: str, password_hash: str, now: str) -> None:
    conn.execute(
        sa.update(users)
        .where(users.c.id == user_id)
        .values(
            password_hash=password_hash,
            password_changed_at=now,
            failed_logins=0,
            locked_until=None,
            updated_at=now,
            version=users.c.version + 1,
        )
    )


def set_status(conn: Connection, user_id: str, status: str, now: str) -> int:
    return conn.execute(
        sa.update(users)
        .where(users.c.id == user_id)
        .values(status=status, updated_at=now, version=users.c.version + 1)
    ).rowcount
