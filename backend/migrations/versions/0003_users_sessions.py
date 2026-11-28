"""Users and sessions: sign-in accounts and their tokens (hashes only).

Mirrors app/modules/users/models.py and app/modules/auth/models.py;
tests/test_models_match_migrations.py fails if the two drift apart.

Revision: 0003
Previous: 0002
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0003"
down_revision: str | Sequence[str] | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Text, primary_key=True),
        sa.Column(
            "tenant_id",
            sa.Text,
            sa.ForeignKey("tenants.id", name="fk_users_tenant_id_tenants"),
            nullable=False,
        ),
        sa.Column("username", sa.Text, nullable=False),
        sa.Column("display_name", sa.Text, nullable=False),
        sa.Column("email", sa.Text),
        sa.Column("password_hash", sa.Text, nullable=False),
        sa.Column("status", sa.Text, nullable=False, server_default="active"),
        sa.Column("failed_logins", sa.Integer, nullable=False, server_default="0"),
        sa.Column("locked_until", sa.Text),
        sa.Column("password_changed_at", sa.Text, nullable=False),
        sa.Column("last_login_at", sa.Text),
        sa.Column("created_at", sa.Text, nullable=False),
        sa.Column("updated_at", sa.Text, nullable=False),
        sa.Column("version", sa.Integer, nullable=False, server_default="1"),
        sa.UniqueConstraint("tenant_id", "username", name="uq_users_tenant_id_username"),
    )
    op.create_table(
        "sessions",
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
        sa.Column("access_hash", sa.Text, nullable=False),
        sa.Column("access_expires_at", sa.Text, nullable=False),
        sa.Column("refresh_hash", sa.Text, nullable=False),
        sa.Column("refresh_expires_at", sa.Text, nullable=False),
        sa.Column("created_at", sa.Text, nullable=False),
        sa.Column("revoked_at", sa.Text),
        sa.Column("revoked_reason", sa.Text),
        sa.UniqueConstraint("access_hash", name="uq_sessions_access_hash"),
        sa.UniqueConstraint("refresh_hash", name="uq_sessions_refresh_hash"),
    )
    op.create_index("ix_sessions_user_id", "sessions", ["user_id"])
    op.create_index("ix_sessions_family_id", "sessions", ["family_id"])


def downgrade() -> None:
    # Forward-only in production: restore from backup instead of downgrading.
    op.drop_index("ix_sessions_family_id", table_name="sessions")
    op.drop_index("ix_sessions_user_id", table_name="sessions")
    op.drop_table("sessions")
    op.drop_table("users")
