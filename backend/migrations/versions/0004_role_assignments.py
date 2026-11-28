"""Role assignments: who holds which role, where.

Mirrors app/modules/roles/models.py (checked by
tests/test_models_match_migrations.py).

Revision: 0004
Previous: 0003
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0004"
down_revision: str | Sequence[str] | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "role_assignments",
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
        sa.Column("granted_by", sa.Text),
        sa.Column("created_at", sa.Text, nullable=False),
        sa.UniqueConstraint(
            "user_id", "role", "scope_type", "scope_id", name="uq_role_assignments_grant"
        ),
    )
    op.create_index("ix_role_assignments_user_id", "role_assignments", ["user_id"])


def downgrade() -> None:
    # Forward-only in production: restore from backup instead of downgrading.
    op.drop_index("ix_role_assignments_user_id", table_name="role_assignments")
    op.drop_table("role_assignments")
