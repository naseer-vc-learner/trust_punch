"""Migrations keep existing data: a database made before migrations existed
upgrades in place, and running them again changes nothing."""

import sqlite3

from app.core.db import migrate, schema_status

# The start-up schema of the first server version, before `via` existed.
OLD_SCHEMA = """
CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL, last_seen_at TEXT,
  blocked INTEGER NOT NULL DEFAULT 0);
CREATE TABLE pair_codes (code_hash TEXT PRIMARY KEY, created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL, used_at TEXT, failed INTEGER NOT NULL DEFAULT 0);
CREATE TABLE sites (site_id TEXT PRIMARY KEY, name TEXT NOT NULL, lat REAL NOT NULL,
  lng REAL NOT NULL, first_seen_at TEXT NOT NULL, first_device TEXT NOT NULL);
CREATE TABLE punches (id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices (id),
  worker_id TEXT NOT NULL, employee_id TEXT NOT NULL, worker_name TEXT NOT NULL,
  site_id TEXT NOT NULL, site_name TEXT NOT NULL, type TEXT NOT NULL, at_utc TEXT NOT NULL,
  offset_minutes INTEGER NOT NULL, local_day TEXT NOT NULL, lat REAL NOT NULL,
  lng REAL NOT NULL, distance REAL NOT NULL, auto INTEGER NOT NULL, corrected INTEGER NOT NULL,
  clock_suspect INTEGER NOT NULL, replaces TEXT, superseded_by TEXT, received_at TEXT NOT NULL,
  clock_skew_s REAL NOT NULL, flags TEXT NOT NULL DEFAULT '');
CREATE INDEX punches_worker_day ON punches (worker_id, local_day);
INSERT INTO devices VALUES ('d1', 'Gate', 'android', 'h1', '2026-11-01T00:00:00+00:00', NULL, 0);
INSERT INTO punches VALUES ('p1', 'd1', 'w1', 'E1', 'Asha', 'gate-a', 'Gate A', 'checkIn',
  '2026-11-01T05:00:00+00:00', 240, '2026-11-01', 25.2, 55.27, 10, 0, 0, 0, NULL, NULL,
  '2026-11-01T05:00:01+00:00', 0.5, '');
"""

DEFAULT_TENANT = "00000000-0000-7000-8000-000000000001"


def _old_db(path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(OLD_SCHEMA)
    conn.commit()
    conn.close()


def test_an_old_database_upgrades_and_keeps_its_rows(tmp_path):
    path = str(tmp_path / "old.db")
    _old_db(path)

    migrate(path)

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    punch = conn.execute("SELECT * FROM punches WHERE id = 'p1'").fetchone()
    assert punch["worker_name"] == "Asha"
    assert punch["via"] is None  # added column
    assert punch["tenant_id"] == DEFAULT_TENANT
    device = conn.execute("SELECT tenant_id FROM devices WHERE id = 'd1'").fetchone()
    assert device["tenant_id"] == DEFAULT_TENANT
    indexes = {r["name"] for r in conn.execute("PRAGMA index_list(punches)")}
    assert "punches_worker_day" in indexes
    conn.close()

    current, head = schema_status(path)
    assert current == head


def test_running_migrations_twice_changes_nothing(tmp_path):
    path = str(tmp_path / "twice.db")
    migrate(path)
    migrate(path)
    conn = sqlite3.connect(path)
    assert conn.execute("SELECT COUNT(*) FROM tenants").fetchone()[0] == 1
    conn.close()


def test_new_rows_belong_to_the_default_tenant(tmp_path):
    path = str(tmp_path / "new.db")
    migrate(path)
    conn = sqlite3.connect(path)
    conn.execute(
        "INSERT INTO pair_codes (code_hash, created_at, expires_at) VALUES ('c', 'a', 'b')"
    )
    assert conn.execute("SELECT tenant_id FROM pair_codes").fetchone()[0] == DEFAULT_TENANT
    conn.close()
