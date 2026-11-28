"""The server's database: connections, and migrations that keep its shape current.

The schema is owned by Alembic (backend/migrations). `migrate()` brings any
database, including one made before migrations existed, up to the newest
revision; the server runs it at start-up and the CLI before every command.

Queries in the existing modules still use sqlite3 directly through
`connect()`. Each module moves to SQLAlchemy when its day in the plan
rebuilds it, which is what makes PostgreSQL possible later.
"""

import sqlite3
from collections.abc import Iterator
from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine

from .config import BACKEND_DIR, get_settings


def db_path() -> str:
    return get_settings().db


def _alembic_config(path: str) -> Config:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    cfg.set_main_option("sqlalchemy.url", f"sqlite:///{path}")
    # Running inside the app: keep the app's logging setup as it is.
    cfg.attributes["configure_logger"] = False
    return cfg


def migrate(path: str | None = None) -> None:
    """Upgrades the database at [path] (default: the configured one) to head."""
    path = path or db_path()
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    command.upgrade(_alembic_config(path), "head")


def schema_status(path: str | None = None) -> tuple[str | None, str | None]:
    """(revision the database is at, newest revision the code knows)."""
    path = path or db_path()
    head = ScriptDirectory.from_config(_alembic_config(path)).get_current_head()
    engine = create_engine(f"sqlite:///{path}")
    try:
        with engine.connect() as conn:
            current = MigrationContext.configure(conn).get_current_revision()
    finally:
        engine.dispose()
    return current, head


def connect(path: str | None = None) -> sqlite3.Connection:
    """A connection to an already migrated database."""
    path = path or db_path()
    conn = sqlite3.connect(path, isolation_level=None)  # explicit BEGIN/COMMIT
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def get_db() -> Iterator[sqlite3.Connection]:
    """FastAPI dependency: one connection per request."""
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()
