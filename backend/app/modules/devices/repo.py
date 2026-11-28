"""SQL for devices and pairing codes."""

import sqlite3


def insert_pair_code(conn: sqlite3.Connection, code_hash: str, created: str, expires: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO pair_codes (code_hash, created_at, expires_at) VALUES (?, ?, ?)",
        (code_hash, created, expires),
    )


def find_open_code(
    conn: sqlite3.Connection, code_hash: str, now: str, max_failed: int
) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT code_hash FROM pair_codes WHERE code_hash = ?"
        " AND used_at IS NULL AND expires_at > ? AND failed < ?",
        (code_hash, now, max_failed),
    ).fetchone()


def count_failure_on_open_codes(conn: sqlite3.Connection, now: str) -> None:
    conn.execute(
        "UPDATE pair_codes SET failed = failed + 1 WHERE used_at IS NULL AND expires_at > ?",
        (now,),
    )


def mark_code_used(conn: sqlite3.Connection, code_hash: str, now: str) -> None:
    conn.execute("UPDATE pair_codes SET used_at = ? WHERE code_hash = ?", (now, code_hash))


def insert_device(
    conn: sqlite3.Connection, device_id: str, name: str, platform: str, token_hash: str, now: str
) -> None:
    conn.execute(
        "INSERT INTO devices (id, name, platform, token_hash, created_at) VALUES (?, ?, ?, ?, ?)",
        (device_id, name, platform, token_hash, now),
    )


def by_token_hash(conn: sqlite3.Connection, token_hash: str) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM devices WHERE token_hash = ?", (token_hash,)).fetchone()


def touch(conn: sqlite3.Connection, device_id: str, now: str) -> None:
    conn.execute("UPDATE devices SET last_seen_at = ? WHERE id = ?", (now, device_id))


def all_devices(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT id, name, platform, created_at, last_seen_at, blocked"
        " FROM devices ORDER BY created_at"
    ).fetchall()


def set_blocked(conn: sqlite3.Connection, device_id: str, blocked: bool) -> int:
    return conn.execute(
        "UPDATE devices SET blocked = ? WHERE id = ?", (1 if blocked else 0, device_id)
    ).rowcount
