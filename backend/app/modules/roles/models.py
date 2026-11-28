"""The role_assignments table (migration 0004).

One row per (user, role, scope). scope_type is tenant | region | site | team;
scope_id is the tenant's id for tenant-wide roles.
"""

import sqlalchemy as sa

from app.core.db import metadata

role_assignments = sa.Table(
    "role_assignments",
    metadata,
    sa.Column("id", sa.Text, primary_key=True),
    sa.Column(
        "tenant_id",
        sa.Text,
        sa.ForeignKey("tenants.id", name="fk_role_assignments_tenant_id_tenants"),
        nullable=False,
    ),
    sa.Column(
        "user_id",
        sa.Text,
        sa.ForeignKey("users.id", name="fk_role_assignments_user_id_users"),
        nullable=False,
    ),
    sa.Column("role", sa.Text, nullable=False),
    sa.Column("scope_type", sa.Text, nullable=False),
    sa.Column("scope_id", sa.Text, nullable=False),
    # Who granted it; empty when an operator used the CLI on the server itself.
    sa.Column("granted_by", sa.Text),
    sa.Column("created_at", sa.Text, nullable=False),
    sa.UniqueConstraint(
        "user_id", "role", "scope_type", "scope_id", name="uq_role_assignments_grant"
    ),
    sa.Index("ix_role_assignments_user_id", "user_id"),
)
