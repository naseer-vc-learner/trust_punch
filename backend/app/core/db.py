"""The server's database: connections, and migrations that keep its shape current.

The schema is owned by Alembic (backend/migrations). `migrate()` brings any
database, including one made before migrations existed, up to the newest
revision; the server runs it at start-up and the CLI before every command.

Two ways in:

- New modules (users, auth, ...) use SQLAlchemy Core: tables are declared
  on `metadata` in each module's models.py and queried through `get_conn()`.
  That code runs unchanged on PostgreSQL later.
- Older modules (devices, attendance) still use sqlite3 through `connect()`
  until their day in the plan rebuilds them.

SQLAlchemy connections "commit as you go": a service calls `conn.commit()`
when its work is done; anything not committed is rolled back when the
request ends. That lets a service record a failed login and still refuse it.
"""

import sqlite3
from collections.abc import Iterator
from pathlib import Path
from typing import Annotated, Any

from alembic import command
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from fastapi import Depends
from sqlalchemy import Connection, Engine, MetaData, create_engine, event

from .config import BACKEND_DIR, get_settings

# Every SQLAlchemy table, from every module's models.py. Constraint names
# follow one pattern so migrations and models agree on them.
metadata = MetaData(
    naming_convention={
        "ix": "ix_%(table_name)s_%(column_0_N_name)s",
        "uq": "uq_%(table_name)s_%(column_0_N_name)s",
        "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
        "pk": "pk_%(table_name)s",
    }
)

_engines: dict[str, Engine] = {}


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
    """FastAPI dependency: one sqlite3 connection per request (older modules)."""
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()


def _sqlite_pragmas(dbapi_conn: Any, _record: Any) -> None:
    cur = dbapi_conn.cursor()
    cur.execute("PRAGMA journal_mode = WAL")
    cur.execute("PRAGMA foreign_keys = ON")
    cur.execute("PRAGMA busy_timeout = 5000")
    cur.close()


def engine(path: str | None = None) -> Engine:
    """The SQLAlchemy engine for the database at [path] (default: configured)."""
    path = path or db_path()
    found = _engines.get(path)
    if found is None:
        found = create_engine(
            f"sqlite:///{path}",
            # FastAPI runs sync endpoints in a thread pool.
            connect_args={"check_same_thread": False},
        )
        event.listen(found, "connect", _sqlite_pragmas)
        _engines[path] = found
    return found


def dispose_engines() -> None:
    """Closes every pooled connection (tests, shutdown)."""
    for e in _engines.values():
        e.dispose()
    _engines.clear()


def get_conn() -> Iterator[Connection]:
    """FastAPI dependency: one SQLAlchemy connection per request."""
    with engine().connect() as conn:
        yield conn


Conn = Annotated[Connection, Depends(get_conn)]
