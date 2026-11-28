"""The sessions table (migration 0003).

One row per issued token pair. Refreshing revokes the row ("rotated") and
issues a new one in the same family; presenting a rotated refresh token
again means it was copied, so the whole family is revoked.
"""

import sqlalchemy as sa

from app.core.db import metadata

sessions = sa.Table(
    "sessions",
    metadata,
    sa.Column("id", sa.Text, primary_key=True),
    sa.Column(
        "tenant_id",
        sa.Text,
        sa.ForeignKey("tenants.id", name="fk_sessions_tenant_id_tenants"),
        nullable=False,
    ),
    sa.Column(
        "user_id",
        sa.Text,
        sa.ForeignKey("users.id", name="fk_sessions_user_id_users"),
        nullable=False,
    ),
    sa.Column("family_id", sa.Text, nullable=False),
    sa.Column("access_hash", sa.Text, nullable=False),  # SHA-256, never the token
    sa.Column("access_expires_at", sa.Text, nullable=False),
    sa.Column("refresh_hash", sa.Text, nullable=False),
    sa.Column("refresh_expires_at", sa.Text, nullable=False),
    sa.Column("created_at", sa.Text, nullable=False),
    sa.Column("revoked_at", sa.Text),
    # rotated | logout | logout_all | password_changed | reuse_detected | user_disabled
    sa.Column("revoked_reason", sa.Text),
    sa.UniqueConstraint("access_hash", name="uq_sessions_access_hash"),
    sa.UniqueConstraint("refresh_hash", name="uq_sessions_refresh_hash"),
    sa.Index("ix_sessions_user_id", "user_id"),
    sa.Index("ix_sessions_family_id", "family_id"),
)
