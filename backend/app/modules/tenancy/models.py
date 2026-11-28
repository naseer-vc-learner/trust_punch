"""The tenants table (created by migration 0002)."""

import sqlalchemy as sa

from app.core.db import metadata

tenants = sa.Table(
    "tenants",
    metadata,
    sa.Column("id", sa.Text, primary_key=True),
    sa.Column("name", sa.Text, nullable=False),
    sa.Column("timezone", sa.Text, nullable=False, server_default="Asia/Dubai"),
    sa.Column("created_at", sa.Text, nullable=False),
)
