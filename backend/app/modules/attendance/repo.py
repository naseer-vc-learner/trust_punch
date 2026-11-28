"""SQL for punches and the locations the server has seen."""

import sqlite3


def day_rows(conn: sqlite3.Connection, worker_id: str, day: str) -> list[sqlite3.Row]:
    """One worker's day as the server holds it, from every phone, in time order."""
    return conn.execute(
        "SELECT id, type, flags, device_id, auto, corrected FROM punches"
        " WHERE worker_id = ? AND local_day = ? AND superseded_by IS NULL"
        " ORDER BY at_utc, id",
        (worker_id, day),
    ).fetchall()


def punch_identity(conn: sqlite3.Connection, punch_id: str) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT device_id, type, at_utc, worker_id FROM punches WHERE id = ?", (punch_id,)
    ).fetchone()


def site(conn: sqlite3.Connection, site_id: str) -> sqlite3.Row | None:
    return conn.execute("SELECT lat, lng FROM sites WHERE site_id = ?", (site_id,)).fetchone()


def insert_site(
    conn: sqlite3.Connection,
    site_id: str,
    name: str,
    lat: float,
    lng: float,
    seen_at: str,
    device_id: str,
) -> None:
    conn.execute(
        "INSERT INTO sites (site_id, name, lat, lng, first_seen_at, first_device)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        (site_id, name, lat, lng, seen_at, device_id),
    )


INSERT_PUNCH = (
    "INSERT INTO punches (id, device_id, worker_id, employee_id,"
    " worker_name, site_id, site_name, type, at_utc, offset_minutes,"
    " local_day, lat, lng, distance, auto, corrected, clock_suspect,"
    " replaces, received_at, clock_skew_s, flags, via)"
    " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
)


def insert_punch(conn: sqlite3.Connection, values: tuple[object, ...]) -> None:
    """[values] in the column order of INSERT_PUNCH."""
    conn.execute(INSERT_PUNCH, values)


def supersede(conn: sqlite3.Connection, old_id: str, new_id: str) -> None:
    conn.execute("UPDATE punches SET superseded_by = ? WHERE id = ?", (new_id, old_id))


def set_flags(conn: sqlite3.Connection, punch_id: str, flags: str) -> None:
    conn.execute("UPDATE punches SET flags = ? WHERE id = ?", (flags, punch_id))


def flags_of(conn: sqlite3.Connection, punch_id: str) -> str:
    row = conn.execute("SELECT flags FROM punches WHERE id = ?", (punch_id,)).fetchone()
    return row["flags"] if row else ""


def report_day(conn: sqlite3.Connection, day: str) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT worker_name, employee_id, site_name, type, at_utc,"
        " offset_minutes, auto, corrected, superseded_by, flags"
        " FROM punches WHERE local_day = ? ORDER BY worker_name, at_utc",
        (day,),
    ).fetchall()
