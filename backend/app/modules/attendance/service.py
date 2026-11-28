"""Storing punches once, and re-checking what the phone claims.

The phone stays the place where attendance happens (face, liveness, GPS);
the server keeps its own copy and flags what does not add up (checks.py).
Flags are for a supervisor, never refusals.
"""

import sqlite3
from datetime import UTC, datetime, timedelta

from . import checks, repo
from .schemas import OpenSession, PunchBatch, Rejected, UploadResult


def _now() -> datetime:
    return datetime.now(UTC)


def open_session(conn: sqlite3.Connection, worker_id: str, day: str, device_id: str) -> OpenSession:
    """Whether [worker_id] is checked in right now, and whether on [device_id].

    A phone asks before punching, so one person cannot be on the clock on
    the gate phone and their own phone at once. [day] is the phone's local
    date. Only what has reached the server counts.
    """
    _, phone = checks.session_phones(repo.day_rows(conn, worker_id, day))
    if phone is None:
        return OpenSession(open=False, onThisPhone=False)
    return OpenSession(open=True, onThisPhone=phone == device_id)


def upload(conn: sqlite3.Connection, batch: PunchBatch, device_id: str) -> UploadResult:
    """Stores each punch once and says what happened to each.

    accepted: stored now; duplicates: already stored (a resend after a lost
    answer), counted as done; rejected: never stored, with the reason.
    flags: the server's own findings for accepted punches.
    """
    received = _now()
    skew = (batch.sentAt - received).total_seconds()
    accepted: list[str] = []
    duplicates: list[str] = []
    rejected: list[Rejected] = []
    days: set[tuple[str, str]] = set()

    conn.execute("BEGIN IMMEDIATE")
    try:
        for p in batch.punches:
            pid = str(p.id)
            at_utc = p.at.astimezone(UTC)
            existing = repo.punch_identity(conn, pid)
            if existing is not None:
                same = (
                    existing["device_id"] == device_id
                    and existing["type"] == p.type
                    and existing["at_utc"] == at_utc.isoformat()
                    and existing["worker_id"] == p.workerId
                )
                if same:
                    duplicates.append(pid)
                else:
                    rejected.append(Rejected(id=pid, reason="conflict"))
                continue

            flags: list[str] = []
            if abs(skew) > checks.CLOCK_TOLERANCE_S:
                flags.append(checks.CLOCK_SKEW)
            if at_utc > received + timedelta(seconds=checks.CLOCK_TOLERANCE_S):
                flags.append(checks.FUTURE_TIME)
            if p.siteLat is not None and p.siteLng is not None:
                if not (p.auto or p.corrected):
                    flags += checks.location_flags(p.lat, p.lng, p.distance, p.siteLat, p.siteLng)
                known = repo.site(conn, p.siteId)
                if known is None:
                    repo.insert_site(
                        conn,
                        p.siteId,
                        p.siteName,
                        p.siteLat,
                        p.siteLng,
                        received.isoformat(),
                        device_id,
                    )
                elif (
                    checks.haversine_m(known["lat"], known["lng"], p.siteLat, p.siteLng)
                    > checks.GEOFENCE_M
                ):
                    flags.append(checks.SITE_MOVED)

            local_day = (at_utc + timedelta(minutes=p.offsetMinutes)).date().isoformat()
            repo.insert_punch(
                conn,
                (
                    pid,
                    device_id,
                    p.workerId,
                    p.employeeId,
                    p.workerName,
                    p.siteId,
                    p.siteName,
                    p.type,
                    at_utc.isoformat(),
                    p.offsetMinutes,
                    local_day,
                    p.lat,
                    p.lng,
                    p.distance,
                    int(p.auto),
                    int(p.corrected),
                    int(p.clockSuspect),
                    str(p.replaces) if p.replaces else None,
                    received.isoformat(),
                    skew,
                    ",".join(flags),
                    p.via,
                ),
            )
            if p.replaces:
                repo.supersede(conn, str(p.replaces), pid)
            accepted.append(pid)
            days.add((p.workerId, local_day))

        # The day as the server now holds it, from every phone: a punch that
        # breaks the sequence is flagged (e.g. checked in on two phones).
        for worker_id, day in days:
            rows = repo.day_rows(conn, worker_id, day)
            marks: dict[int, list[str]] = {}
            bad = checks.first_out_of_order([r["type"] for r in rows])
            if bad is not None:
                marks.setdefault(bad, []).append(checks.OUT_OF_ORDER)
            other, _ = checks.session_phones(rows)
            for i in other:
                marks.setdefault(i, []).append(checks.OTHER_PHONE)
            for i, new in marks.items():
                merged = rows[i]["flags"]
                for flag in new:
                    merged = checks.add_flag(merged, flag)
                repo.set_flags(conn, rows[i]["id"], merged)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise

    flagged: dict[str, list[str]] = {}
    for pid in accepted:
        stored = repo.flags_of(conn, pid)
        if stored:
            flagged[pid] = stored.split(",")

    return UploadResult(
        accepted=accepted,
        duplicates=duplicates,
        rejected=rejected,
        flags=flagged,
        serverTime=received.isoformat(),
    )


def report_day(conn: sqlite3.Connection, day: str) -> list[sqlite3.Row]:
    return repo.report_day(conn, day)
