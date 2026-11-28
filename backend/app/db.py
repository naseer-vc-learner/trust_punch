"""The server's own record, in SQLite.

One file (``data/trustpunch.db`` by default, ``TRUSTPUNCH_DB`` to move it).
Fine for a local service; a real deployment would move to PostgreSQL, and
nothing here depends on SQLite beyond the connection.
"""

import os
import sqlite3
from collections.abc import Iterator
from pathlib import Path

_DEFAULT = Path(__file__).resolve().parent.parent / "data" / "trustpunch.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    platform      TEXT NOT NULL,
    token_hash    TEXT NOT NULL UNIQUE,   -- SHA-256 of the token, never the token
    created_at    TEXT NOT NULL,
    last_seen_at  TEXT,
    blocked       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS pair_codes (
    code_hash   TEXT PRIMARY KEY,
    created_at  TEXT NOT NULL,
    expires_at  TEXT NOT NULL,
    used_at     TEXT,
    failed      INTEGER NOT NULL DEFAULT 0   -- wrong guesses while it was open
);

-- Where each location is, as first reported. A later punch claiming the
-- same location somewhere else is flagged.
CREATE TABLE IF NOT EXISTS sites (
    site_id        TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    lat            REAL NOT NULL,
    lng            REAL NOT NULL,
    first_seen_at  TEXT NOT NULL,
    first_device   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS punches (
    id               TEXT PRIMARY KEY,    -- made on the phone: resending is harmless
    device_id        TEXT NOT NULL REFERENCES devices (id),
    worker_id        TEXT NOT NULL,
    employee_id      TEXT NOT NULL,
    worker_name      TEXT NOT NULL,
    site_id          TEXT NOT NULL,
    site_name        TEXT NOT NULL,
    type             TEXT NOT NULL,
    at_utc           TEXT NOT NULL,       -- the phone's time for the punch
    offset_minutes   INTEGER NOT NULL,    -- the phone's time zone then
    local_day        TEXT NOT NULL,       -- YYYY-MM-DD in that time zone
    lat              REAL NOT NULL,
    lng              REAL NOT NULL,
    distance         REAL NOT NULL,       -- as the phone reported it
    auto             INTEGER NOT NULL,
    corrected        INTEGER NOT NULL,
    clock_suspect    INTEGER NOT NULL,    -- the phone's own GPS-clock flag
    replaces         TEXT,                -- a corrected punch replacing this id
    superseded_by    TEXT,
    received_at      TEXT NOT NULL,       -- the server's time, not the phone's
    clock_skew_s     REAL NOT NULL,       -- phone clock minus server clock
    flags            TEXT NOT NULL DEFAULT '',  -- the server's own findings
    via              TEXT                 -- ownPhone / gate; null when automatic
);
CREATE INDEX IF NOT EXISTS punches_worker_day ON punches (worker_id, local_day);
"""


def db_path() -> str:
    return os.environ.get("TRUSTPUNCH_DB", str(_DEFAULT))


def connect(path: str | None = None) -> sqlite3.Connection:
    path = path or db_path()
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, isolation_level=None)  # explicit BEGIN/COMMIT
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(SCHEMA)
    _upgrade(conn)
    return conn


def _upgrade(conn: sqlite3.Connection) -> None:
    """Columns added after a database was first made."""
    columns = {r["name"] for r in conn.execute("PRAGMA table_info(punches)")}
    if "via" not in columns:
        conn.execute("ALTER TABLE punches ADD COLUMN via TEXT")


def get_db() -> Iterator[sqlite3.Connection]:
    """FastAPI dependency: one connection per request."""
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()
