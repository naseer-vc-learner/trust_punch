"""The users table (migration 0003). Times are ISO 8601 UTC text, as elsewhere."""

import sqlalchemy as sa

from app.core.db import metadata

users = sa.Table(
    "users",
    metadata,
    sa.Column("id", sa.Text, primary_key=True),
    sa.Column(
        "tenant_id",
        sa.Text,
        sa.ForeignKey("tenants.id", name="fk_users_tenant_id_tenants"),
        nullable=False,
    ),
    # Lower-case; unique within a tenant.
    sa.Column("username", sa.Text, nullable=False),
    sa.Column("display_name", sa.Text, nullable=False),
    sa.Column("email", sa.Text),
    sa.Column("password_hash", sa.Text, nullable=False),  # argon2id, never the password
    sa.Column("status", sa.Text, nullable=False, server_default="active"),  # active | disabled
    sa.Column("failed_logins", sa.Integer, nullable=False, server_default="0"),
    sa.Column("locked_until", sa.Text),
    sa.Column("password_changed_at", sa.Text, nullable=False),
    sa.Column("last_login_at", sa.Text),
    sa.Column("created_at", sa.Text, nullable=False),
    sa.Column("updated_at", sa.Text, nullable=False),
    sa.Column("version", sa.Integer, nullable=False, server_default="1"),
    sa.UniqueConstraint("tenant_id", "username", name="uq_users_tenant_id_username"),
)
