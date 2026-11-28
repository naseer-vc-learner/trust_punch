"""Baseline: the schema as it was before migrations existed (Day 0).

Every statement is "create if missing", so this runs safely on a database
made by the old start-up code (it only adds what is missing, e.g. the `via`
column of older databases) and on an empty one alike. No manual stamping.

Revision: 0001
Previous: none
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0001"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "devices",
        sa.Column("id", sa.Text, primary_key=True),
        sa.Column("name", sa.Text, nullable=False),
        sa.Column("platform", sa.Text, nullable=False),
        # SHA-256 of the token, never the token.
        sa.Column("token_hash", sa.Text, nullable=False, unique=True),
        sa.Column("created_at", sa.Text, nullable=False),
        sa.Column("last_seen_at", sa.Text),
        sa.Column("blocked", sa.Integer, nullable=False, server_default="0"),
        if_not_exists=True,
    )
    op.create_table(
        "pair_codes",
        sa.Column("code_hash", sa.Text, primary_key=True),
        sa.Column("created_at", sa.Text, nullable=False),
        sa.Column("expires_at", sa.Text, nullable=False),
        sa.Column("used_at", sa.Text),
        # Wrong guesses while it was open.
        sa.Column("failed", sa.Integer, nullable=False, server_default="0"),
        if_not_exists=True,
    )
    # Where each location is, as first reported. A later punch claiming the
    # same location somewhere else is flagged.
    op.create_table(
        "sites",
        sa.Column("site_id", sa.Text, primary_key=True),
        sa.Column("name", sa.Text, nullable=False),
        sa.Column("lat", sa.Float, nullable=False),
        sa.Column("lng", sa.Float, nullable=False),
        sa.Column("first_seen_at", sa.Text, nullable=False),
        sa.Column("first_device", sa.Text, nullable=False),
        if_not_exists=True,
    )
    op.create_table(
        "punches",
        # Made on the phone: resending is harmless.
        sa.Column("id", sa.Text, primary_key=True),
        sa.Column("device_id", sa.Text, sa.ForeignKey("devices.id"), nullable=False),
        sa.Column("worker_id", sa.Text, nullable=False),
        sa.Column("employee_id", sa.Text, nullable=False),
        sa.Column("worker_name", sa.Text, nullable=False),
        sa.Column("site_id", sa.Text, nullable=False),
        sa.Column("site_name", sa.Text, nullable=False),
        sa.Column("type", sa.Text, nullable=False),
        sa.Column("at_utc", sa.Text, nullable=False),  # the phone's time for the punch
        sa.Column("offset_minutes", sa.Integer, nullable=False),  # the phone's time zone then
        sa.Column("local_day", sa.Text, nullable=False),  # YYYY-MM-DD in that time zone
        sa.Column("lat", sa.Float, nullable=False),
        sa.Column("lng", sa.Float, nullable=False),
        sa.Column("distance", sa.Float, nullable=False),  # as the phone reported it
        sa.Column("auto", sa.Integer, nullable=False),
        sa.Column("corrected", sa.Integer, nullable=False),
        sa.Column("clock_suspect", sa.Integer, nullable=False),  # the phone's own flag
        sa.Column("replaces", sa.Text),  # a corrected punch replacing this id
        sa.Column("superseded_by", sa.Text),
        sa.Column("received_at", sa.Text, nullable=False),  # the server's time
        sa.Column("clock_skew_s", sa.Float, nullable=False),  # phone minus server
        sa.Column("flags", sa.Text, nullable=False, server_default=""),
        sa.Column("via", sa.Text),  # ownPhone / gate; null when automatic
        if_not_exists=True,
    )
    op.create_index("punches_worker_day", "punches", ["worker_id", "local_day"], if_not_exists=True)

    # Databases made before `via` existed.
    columns = {c["name"] for c in sa.inspect(op.get_bind()).get_columns("punches")}
    if "via" not in columns:
        op.add_column("punches", sa.Column("via", sa.Text))


def downgrade() -> None:
    # Forward-only in production: restore from backup instead of downgrading.
    op.drop_index("punches_worker_day", table_name="punches")
    for table in ("punches", "sites", "pair_codes", "devices"):
        op.drop_table(table)
