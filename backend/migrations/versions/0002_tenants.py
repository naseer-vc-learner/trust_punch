"""Tenants: every row belongs to a company.

Adds a `tenants` table with one default tenant, and `tenant_id` on every
existing table. Existing rows (and rows written by code that does not set
it yet) belong to the default tenant. From Day 4 the session decides the
tenant and every query filters by it; see the plan, decision A3.

Revision: 0002
Previous: 0001
"""

from collections.abc import Sequence
from datetime import UTC, datetime

import sqlalchemy as sa
from alembic import op

revision: str = "0002"
down_revision: str | Sequence[str] | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

DEFAULT_TENANT_ID = "00000000-0000-7000-8000-000000000001"
TABLES = ("devices", "pair_codes", "sites", "punches")


def upgrade() -> None:
    tenants = op.create_table(
        "tenants",
        sa.Column("id", sa.Text, primary_key=True),
        sa.Column("name", sa.Text, nullable=False),
        sa.Column("timezone", sa.Text, nullable=False, server_default="Asia/Dubai"),
        sa.Column("created_at", sa.Text, nullable=False),
    )
    op.bulk_insert(
        tenants,
        [
            {
                "id": DEFAULT_TENANT_ID,
                "name": "Default company",
                "timezone": "Asia/Dubai",
                "created_at": datetime.now(UTC).isoformat(),
            }
        ],
    )
    for table in TABLES:
        with op.batch_alter_table(table) as batch:
            batch.add_column(
                sa.Column(
                    "tenant_id",
                    sa.Text,
                    sa.ForeignKey("tenants.id", name=f"fk_{table}_tenant"),
                    nullable=False,
                    server_default=DEFAULT_TENANT_ID,
                )
            )
        op.create_index(f"{table}_tenant", table, ["tenant_id"])


def downgrade() -> None:
    # Forward-only in production: restore from backup instead of downgrading.
    for table in TABLES:
        op.drop_index(f"{table}_tenant", table_name=table)
        with op.batch_alter_table(table) as batch:
            batch.drop_column("tenant_id")
    op.drop_table("tenants")
