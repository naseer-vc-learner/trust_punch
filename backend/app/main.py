"""TrustPunch API, run on a Mac on the local network.

Step 1: a health check the phone can reach over HTTPS.
Step 2: a phone pairs once, then uploads its punches. The phone stays the
place where attendance happens (face, liveness, GPS); the server keeps its
own copy, stores each punch once, and re-checks what it can (see checks.py).

Only the "connected" app talks to this; the offline demo app never does.
"""

import os
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal
from uuid import UUID

from fastapi import Depends, FastAPI, Header, HTTPException, Path, Query, Request
from fastapi.responses import JSONResponse
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field

from . import checks
from .db import get_db
from .security import PairingRefused, TooManyAttempts, device_for_token, pair_device

VERSION = "0.2.0"
MAX_BODY_BYTES = 2_000_000
MAX_BATCH = 500

# The interactive docs describe every endpoint to anyone who can reach the
# server, so they exist only when a developer turns them on explicitly.
_debug = os.environ.get("TRUSTPUNCH_DEBUG") == "1"

app = FastAPI(
    title="TrustPunch API",
    version=VERSION,
    docs_url="/docs" if _debug else None,
    redoc_url=None,
    openapi_url="/openapi.json" if _debug else None,
)

Db = Annotated[sqlite3.Connection, Depends(get_db)]


@app.middleware("http")
async def limit_body(request: Request, call_next):
    """Refuses oversized requests before reading them."""
    length = request.headers.get("content-length")
    if length is not None and (not length.isdigit() or int(length) > MAX_BODY_BYTES):
        return JSONResponse({"detail": "Request too large"}, status_code=413)
    return await call_next(request)


def _now() -> datetime:
    return datetime.now(timezone.utc)


@app.get("/health")
def health() -> dict:
    """Says the server is up, and what time it thinks it is.

    The phone compares serverTime with its own clock; a large gap is the
    first sign of a tampered clock.
    """
    return {
        "status": "ok",
        "service": "trustpunch-api",
        "version": VERSION,
        "serverTime": _now().isoformat(),
    }


# ------------------------------------------------------------------ devices


class _Strict(BaseModel):
    # Unknown fields are refused, and so are NaN/Infinity in numbers.
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class PairRequest(_Strict):
    code: str = Field(pattern=r"^\d{6}$")
    deviceName: str = Field(min_length=1, max_length=80)
    platform: Literal["ios", "android", "other"]


@app.post("/devices/pair")
def pair(body: PairRequest, request: Request, db: Db) -> dict:
    """Trades a one-time code from the server's operator for a device token."""
    client = request.client.host if request.client else "unknown"
    try:
        device_id, token = pair_device(
            db, body.code, body.deviceName, body.platform, client
        )
    except TooManyAttempts:
        raise HTTPException(429, "Too many wrong codes; wait and ask for a new one")
    except PairingRefused:
        raise HTTPException(403, "Code not valid")
    return {"deviceId": device_id, "token": token}


def current_device(
    db: Db, authorization: Annotated[str | None, Header()] = None
) -> sqlite3.Row:
    """The paired, unblocked phone making this request."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Not paired")
    device = device_for_token(db, authorization.removeprefix("Bearer ").strip())
    if device is None:
        raise HTTPException(401, "Not paired")
    if device["blocked"]:
        raise HTTPException(403, "This phone is blocked")
    db.execute(
        "UPDATE devices SET last_seen_at = ? WHERE id = ?",
        (_now().isoformat(), device["id"]),
    )
    return device


Device = Annotated[sqlite3.Row, Depends(current_device)]


@app.get("/devices/me")
def me(device: Device) -> dict:
    return {"deviceId": device["id"], "name": device["name"]}


# ------------------------------------------------------------------ punches


class PunchIn(_Strict):
    id: UUID
    type: Literal["checkIn", "breakStart", "breakEnd", "checkOut"]
    at: AwareDatetime
    offsetMinutes: int = Field(ge=-14 * 60, le=14 * 60)
    workerId: str = Field(min_length=1, max_length=100)
    employeeId: str = Field(max_length=100)
    workerName: str = Field(max_length=200)
    siteId: str = Field(min_length=1, max_length=100)
    siteName: str = Field(max_length=200)
    # Where the phone has the location; missing when it was deleted since.
    siteLat: float | None = Field(default=None, ge=-90, le=90)
    siteLng: float | None = Field(default=None, ge=-180, le=180)
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    distance: float = Field(ge=0, le=20_000_000)
    auto: bool = False
    corrected: bool = False
    clockSuspect: bool = False
    replaces: UUID | None = None
    # How the worker made it; absent for automatic and corrected punches.
    via: Literal["ownPhone", "gate"] | None = None


class PunchBatch(_Strict):
    # The phone's clock when it sent this, compared with the server's.
    sentAt: AwareDatetime
    punches: list[PunchIn] = Field(max_length=MAX_BATCH)


def _day_rows(db: sqlite3.Connection, worker_id: str, day: str) -> list[sqlite3.Row]:
    """One worker's day as the server holds it, from every phone."""
    return db.execute(
        "SELECT id, type, flags, device_id, auto, corrected FROM punches"
        " WHERE worker_id = ? AND local_day = ? AND superseded_by IS NULL"
        " ORDER BY at_utc, id",
        (worker_id, day),
    ).fetchall()


@app.get("/workers/{worker_id}/open-session")
def open_session(
    worker_id: Annotated[str, Path(min_length=1, max_length=100)],
    day: Annotated[str, Query(pattern=r"^\d{4}-\d{2}-\d{2}$")],
    device: Device,
    db: Db,
) -> dict:
    """Whether [worker_id] is checked in right now, and on which phone.

    A phone asks before punching, so one person cannot be on the clock on
    the gate phone and their own phone at once. [day] is the phone's local
    date. Only what has reached the server counts.
    """
    _, phone = checks.session_phones(_day_rows(db, worker_id, day))
    if phone is None:
        return {"open": False, "onThisPhone": False}
    return {"open": True, "onThisPhone": phone == device["id"]}


@app.post("/punches/batch")
def upload_punches(batch: PunchBatch, device: Device, db: Db) -> dict:
    """Stores each punch once and returns what happened to each.

    accepted: stored now; duplicates: already stored (a resend after a lost
    answer), counted as done; rejected: never stored, with the reason.
    flags: the server's own findings for accepted punches.
    """
    received = _now()
    skew = (batch.sentAt - received).total_seconds()
    accepted: list[str] = []
    duplicates: list[str] = []
    rejected: list[dict] = []
    flagged: dict[str, list[str]] = {}
    days: set[tuple[str, str]] = set()

    db.execute("BEGIN IMMEDIATE")
    try:
        for p in batch.punches:
            pid = str(p.id)
            at_utc = p.at.astimezone(timezone.utc)
            existing = db.execute(
                "SELECT device_id, type, at_utc, worker_id FROM punches WHERE id = ?",
                (pid,),
            ).fetchone()
            if existing is not None:
                same = (
                    existing["device_id"] == device["id"]
                    and existing["type"] == p.type
                    and existing["at_utc"] == at_utc.isoformat()
                    and existing["worker_id"] == p.workerId
                )
                if same:
                    duplicates.append(pid)
                else:
                    rejected.append({"id": pid, "reason": "conflict"})
                continue

            flags: list[str] = []
            if abs(skew) > checks.CLOCK_TOLERANCE_S:
                flags.append(checks.CLOCK_SKEW)
            if at_utc > received + timedelta(seconds=checks.CLOCK_TOLERANCE_S):
                flags.append(checks.FUTURE_TIME)
            if p.siteLat is not None and p.siteLng is not None:
                if not (p.auto or p.corrected):
                    flags += checks.location_flags(
                        p.lat, p.lng, p.distance, p.siteLat, p.siteLng
                    )
                known = db.execute(
                    "SELECT lat, lng FROM sites WHERE site_id = ?", (p.siteId,)
                ).fetchone()
                if known is None:
                    db.execute(
                        "INSERT INTO sites (site_id, name, lat, lng, first_seen_at,"
                        " first_device) VALUES (?, ?, ?, ?, ?, ?)",
                        (p.siteId, p.siteName, p.siteLat, p.siteLng,
                         received.isoformat(), device["id"]),
                    )
                elif (
                    checks.haversine_m(known["lat"], known["lng"], p.siteLat, p.siteLng)
                    > checks.GEOFENCE_M
                ):
                    flags.append(checks.SITE_MOVED)

            local_day = (
                at_utc + timedelta(minutes=p.offsetMinutes)
            ).date().isoformat()
            db.execute(
                "INSERT INTO punches (id, device_id, worker_id, employee_id,"
                " worker_name, site_id, site_name, type, at_utc, offset_minutes,"
                " local_day, lat, lng, distance, auto, corrected, clock_suspect,"
                " replaces, received_at, clock_skew_s, flags, via)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (pid, device["id"], p.workerId, p.employeeId, p.workerName,
                 p.siteId, p.siteName, p.type, at_utc.isoformat(), p.offsetMinutes,
                 local_day, p.lat, p.lng, p.distance, int(p.auto), int(p.corrected),
                 int(p.clockSuspect), str(p.replaces) if p.replaces else None,
                 received.isoformat(), skew, ",".join(flags), p.via),
            )
            if p.replaces:
                db.execute(
                    "UPDATE punches SET superseded_by = ? WHERE id = ?",
                    (pid, str(p.replaces)),
                )
            accepted.append(pid)
            days.add((p.workerId, local_day))

        # The day as the server now holds it, from every phone: a punch that
        # breaks the sequence is flagged (e.g. checked in on two phones).
        for worker_id, day in days:
            rows = _day_rows(db, worker_id, day)
            marks = {}
            bad = checks.first_out_of_order([r["type"] for r in rows])
            if bad is not None:
                marks.setdefault(bad, []).append(checks.OUT_OF_ORDER)
            other, _ = checks.session_phones(rows)
            for i in other:
                marks.setdefault(i, []).append(checks.OTHER_PHONE)
            for i, new in marks.items():
                flags = rows[i]["flags"]
                for flag in new:
                    flags = checks.add_flag(flags, flag)
                db.execute("UPDATE punches SET flags = ? WHERE id = ?",
                           (flags, rows[i]["id"]))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise

    for pid in accepted:
        flags = db.execute("SELECT flags FROM punches WHERE id = ?", (pid,)).fetchone()
        if flags and flags["flags"]:
            flagged[pid] = flags["flags"].split(",")

    return {
        "accepted": accepted,
        "duplicates": duplicates,
        "rejected": rejected,
        "flags": flagged,
        "serverTime": received.isoformat(),
    }
