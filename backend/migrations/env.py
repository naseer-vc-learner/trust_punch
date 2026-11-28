"""Alembic environment: where the database is and how migrations run.

The URL comes from the caller (app.core.db.migrate sets it) or, when run
from the command line, from TRUSTPUNCH_DB like the server.
"""

from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.core.config import get_settings

config = context.config

# Configure logging only when run as `alembic ...`, never inside the server,
# whose logging is set up by app.core.logging.
if config.config_file_name and config.attributes.get("configure_logger", True):
    fileConfig(config.config_file_name)

if not config.get_main_option("sqlalchemy.url"):
    config.set_main_option("sqlalchemy.url", f"sqlite:///{get_settings().db}")

# Migrations are written by hand (op.*), so there is no model metadata yet.
target_metadata = None


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        render_as_batch=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with engine.connect() as connection:
        # SQLite can't alter most column properties in place; batch mode
        # rebuilds the table for those, and is a no-op on PostgreSQL.
        context.configure(
            connection=connection, target_metadata=target_metadata, render_as_batch=True
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
