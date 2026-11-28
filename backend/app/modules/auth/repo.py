"""SQL for sessions (SQLAlchemy Core, portable to PostgreSQL)."""

from typing import Any

import sqlalchemy as sa
from sqlalchemy import Connection, RowMapping

from .models import sessions


def insert(conn: Connection, values: dict[str, Any]) -> None:
    conn.execute(sa.insert(sessions).values(**values))


def by_access_hash(conn: Connection, access_hash: str) -> RowMapping | None:
    return (
        conn.execute(sa.select(sessions).where(sessions.c.access_hash == access_hash))
        .mappings()
        .first()
    )


def by_refresh_hash(conn: Connection, refresh_hash: str) -> RowMapping | None:
    return (
        conn.execute(sa.select(sessions).where(sessions.c.refresh_hash == refresh_hash))
        .mappings()
        .first()
    )


def revoke_if_live(conn: Connection, session_id: str, reason: str, now: str) -> bool:
    """Revokes one session unless something else already did; True if this call did.
    Used for rotation: of two refreshes racing with one token, only one wins."""
    result = conn.execute(
        sa.update(sessions)
        .where(sessions.c.id == session_id, sessions.c.revoked_at.is_(None))
        .values(revoked_at=now, revoked_reason=reason)
    )
    return result.rowcount == 1


def revoke_family(conn: Connection, family_id: str, reason: str, now: str) -> None:
    conn.execute(
        sa.update(sessions)
        .where(sessions.c.family_id == family_id, sessions.c.revoked_at.is_(None))
        .values(revoked_at=now, revoked_reason=reason)
    )


def revoke_user(
    conn: Connection, user_id: str, reason: str, now: str, keep_family: str | None = None
) -> None:
    query = sa.update(sessions).where(
        sessions.c.user_id == user_id, sessions.c.revoked_at.is_(None)
    )
    if keep_family is not None:
        query = query.where(sessions.c.family_id != keep_family)
    conn.execute(query.values(revoked_at=now, revoked_reason=reason))
