"""SQL for role assignments (SQLAlchemy Core, portable to PostgreSQL)."""

from typing import Any

import sqlalchemy as sa
from sqlalchemy import Connection, RowMapping

from .models import role_assignments as ra


def for_user(conn: Connection, user_id: str) -> list[RowMapping]:
    return list(
        conn.execute(
            sa.select(ra).where(ra.c.user_id == user_id).order_by(ra.c.created_at, ra.c.id)
        ).mappings()
    )


def by_id(conn: Connection, assignment_id: str) -> RowMapping | None:
    return conn.execute(sa.select(ra).where(ra.c.id == assignment_id)).mappings().first()


def exists(conn: Connection, user_id: str, role: str, scope_type: str, scope_id: str) -> bool:
    return (
        conn.execute(
            sa.select(ra.c.id).where(
                ra.c.user_id == user_id,
                ra.c.role == role,
                ra.c.scope_type == scope_type,
                ra.c.scope_id == scope_id,
            )
        ).first()
        is not None
    )


def insert(conn: Connection, values: dict[str, Any]) -> None:
    conn.execute(sa.insert(ra).values(**values))


def delete(conn: Connection, assignment_id: str) -> None:
    conn.execute(sa.delete(ra).where(ra.c.id == assignment_id))


def count_role(conn: Connection, tenant_id: str, role: str) -> int:
    return conn.execute(
        sa.select(sa.func.count())
        .select_from(ra)
        .where(ra.c.tenant_id == tenant_id, ra.c.role == role)
    ).scalar_one()
