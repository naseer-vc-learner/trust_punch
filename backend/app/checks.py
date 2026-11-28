"""What the server re-checks instead of trusting the phone.

The phone already refuses bad punches; these catch a phone that has been
tampered with, or two phones that disagree. Findings are flags for a
supervisor, not refusals: an honest punch must never be lost because, say,
the phone's clock drifted.
"""

import math
from collections.abc import Sequence

# Same numbers as the app.
GEOFENCE_M = 50.0
CLOCK_TOLERANCE_S = 120.0
# Rounding, and the phone measuring from its own fix a moment earlier.
DISTANCE_SLACK_M = 10.0

CLOCK_SKEW = "clock_skew"           # phone clock differs from the server's
FUTURE_TIME = "future_time"         # punch time later than the server's now
FAR_FROM_SITE = "far_from_site"     # fix is outside the location's circle
DISTANCE_MISMATCH = "distance_mismatch"  # reported distance is not the real one
SITE_MOVED = "site_moved"           # location reported somewhere new
OUT_OF_ORDER = "out_of_order"       # breaks in → (break)* → out for that day
OTHER_PHONE = "other_phone"         # a session continued on a different phone


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def location_flags(
    lat: float,
    lng: float,
    reported_distance: float,
    site_lat: float,
    site_lng: float,
) -> list[str]:
    """For a punch the worker made in person (not automatic or corrected)."""
    flags = []
    real = haversine_m(lat, lng, site_lat, site_lng)
    if real > GEOFENCE_M + DISTANCE_SLACK_M:
        flags.append(FAR_FROM_SITE)
    if abs(real - reported_distance) > DISTANCE_SLACK_M:
        flags.append(DISTANCE_MISMATCH)
    return flags


def first_out_of_order(types: Sequence[str]) -> int | None:
    """Index of the first punch that breaks the day's sequence, or None.

    The same rule as the app's ``validDay``: in → (break start → break
    end)* → out, any number of times; a break may be closed by a check-out.
    """
    state = "off"
    for i, t in enumerate(types):
        if t == "checkIn":
            if state != "off":
                return i
            state = "working"
        elif t == "breakStart":
            if state != "working":
                return i
            state = "break"
        elif t == "breakEnd":
            if state != "break":
                return i
            state = "working"
        elif t == "checkOut":
            if state == "off":
                return i
            state = "off"
    return None


def session_phones(rows) -> tuple[list[int], str | None]:
    """Walks one worker's day (time order, replaced punches left out).

    A session runs from a check-in to the next check-out the worker made;
    the app's automatic check-outs (moving location, shift handover) do not
    end it. Returns the indexes of punches made on a different phone than
    the one the session started on, and the phone holding a session still
    open at the end of the day so far (None when checked out).
    """
    other: list[int] = []
    phone: str | None = None
    for i, r in enumerate(rows):
        made_by_worker = not (r["auto"] or r["corrected"])
        if made_by_worker:
            if phone is None:
                phone = r["device_id"]
            elif r["device_id"] != phone:
                other.append(i)
        if r["type"] == "checkOut" and not r["auto"]:
            phone = None
    open_on = phone if rows and rows[-1]["type"] != "checkOut" else None
    return other, open_on


def add_flag(flags: str, flag: str) -> str:
    parts = [f for f in flags.split(",") if f]
    if flag not in parts:
        parts.append(flag)
    return ",".join(parts)
