import uuid
from datetime import UTC, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.core.db import connect
from app.main import app
from app.modules.devices.service import new_pair_code

client = TestClient(app)

# Dubai, UTC+4. Gate A and a point ~30 m from it.
SITE = {"siteId": "gate-a", "siteName": "Gate A", "siteLat": 25.2048, "siteLng": 55.2708}
NEAR = (25.20507, 55.2708)  # ~30 m north


def _token(name: str = "Gate phone") -> str:
    conn = connect()
    code = new_pair_code(conn)
    conn.close()
    r = client.post("/devices/pair", json={"code": code, "deviceName": name, "platform": "android"})
    return r.json()["token"]


def _punch(type_: str, when: datetime, **over) -> dict:
    p = {
        "id": str(uuid.uuid4()),
        "type": type_,
        "at": when.isoformat(),
        "offsetMinutes": 240,
        "workerId": "w1",
        "employeeId": "E1",
        "workerName": "Asha",
        **SITE,
        "lat": NEAR[0],
        "lng": NEAR[1],
        "distance": 30.0,
    }
    p.update(over)
    return p


def _send(token: str, punches: list[dict], sent_at: datetime | None = None):
    return client.post(
        "/punches/batch",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "sentAt": (sent_at or datetime.now(UTC)).isoformat(),
            "punches": punches,
        },
    )


@pytest.fixture
def token():
    return _token()


def _today(h: int, m: int = 0) -> datetime:
    """Yesterday (Dubai) at h:m, as UTC: one whole day, all in the past."""
    dubai = timezone(timedelta(hours=4))
    day = (datetime.now(dubai) - timedelta(days=1)).date()
    return datetime(day.year, day.month, day.day, h, m, tzinfo=dubai).astimezone(UTC)


def test_a_day_is_stored_once(token):
    day = [_punch("checkIn", _today(7)), _punch("checkOut", _today(16))]
    r = _send(token, day)
    assert r.status_code == 200
    assert sorted(r.json()["accepted"]) == sorted(p["id"] for p in day)
    assert r.json()["flags"] == {}

    # The answer got lost and the phone sends again: nothing doubles.
    again = _send(token, day).json()
    assert again["accepted"] == []
    assert sorted(again["duplicates"]) == sorted(p["id"] for p in day)
    conn = connect()
    assert conn.execute("SELECT count(*) FROM punches").fetchone()[0] == 2
    conn.close()


def test_same_id_different_punch_is_a_conflict(token):
    p = _punch("checkIn", _today(7))
    _send(token, [p])
    r = _send(token, [{**p, "type": "checkOut"}]).json()
    assert r["rejected"] == [{"id": p["id"], "reason": "conflict"}]


def test_another_phone_cannot_claim_an_id(token):
    p = _punch("checkIn", _today(7))
    _send(token, [p])
    other = _token("Other phone")
    assert _send(other, [p]).json()["rejected"][0]["reason"] == "conflict"


def test_the_local_day_follows_the_phone_time_zone(token):
    # 23:30 in Dubai is still the same day there, though 19:30 UTC.
    at = _today(23, 30)
    p = _punch("checkIn", at)
    _send(token, [p])
    conn = connect()
    day = conn.execute("SELECT local_day FROM punches").fetchone()[0]
    conn.close()
    assert day == (at + timedelta(hours=4)).date().isoformat()


class TestServerChecks:
    def test_a_fix_outside_the_circle(self, token):
        far = _punch("checkIn", _today(7), lat=25.2060, lng=55.2708, distance=30.0)
        flags = _send(token, [far]).json()["flags"][far["id"]]
        assert "far_from_site" in flags
        assert "distance_mismatch" in flags  # it claimed 30 m; it is ~130 m

    def test_automatic_punches_skip_the_location_check(self, token):
        auto = _punch("checkIn", _today(7), lat=0.0, lng=0.0, distance=0.0, auto=True)
        assert auto["id"] not in _send(token, [auto]).json()["flags"]

    def test_a_phone_clock_off_by_minutes(self, token):
        p = _punch("checkIn", _today(7))
        r = _send(token, [p], sent_at=datetime.now(UTC) - timedelta(minutes=30))
        assert "clock_skew" in r.json()["flags"][p["id"]]

    def test_a_punch_in_the_future(self, token):
        p = _punch("checkIn", datetime.now(UTC) + timedelta(hours=2))
        assert "future_time" in _send(token, [p]).json()["flags"][p["id"]]

    def test_a_location_reported_somewhere_else(self, token):
        _send(token, [_punch("checkIn", _today(7))])
        moved = _punch("checkOut", _today(16), siteLat=25.30, lat=25.30, distance=0.0)
        assert "site_moved" in _send(token, [moved]).json()["flags"][moved["id"]]

    def test_checked_in_twice_on_two_phones(self, token):
        _send(token, [_punch("checkIn", _today(7))])
        second = _punch("checkIn", _today(7, 5))
        flags = _send(_token("Kiosk"), [second]).json()["flags"][second["id"]]
        assert "out_of_order" in flags


def test_a_correction_replaces_the_automatic_check_out(token):
    in_ = _punch("checkIn", _today(7))
    auto_out = _punch("checkOut", _today(16), auto=True, distance=0.0)
    _send(token, [in_, auto_out])
    fixed = _punch(
        "checkOut", _today(15, 40), corrected=True, distance=0.0, replaces=auto_out["id"]
    )
    r = _send(token, [fixed]).json()
    assert fixed["id"] not in r["flags"], "the day is valid with the replacement"
    conn = connect()
    by = conn.execute(
        "SELECT superseded_by FROM punches WHERE id = ?", (auto_out["id"],)
    ).fetchone()[0]
    conn.close()
    assert by == fixed["id"]


def test_bad_punches_are_refused_whole(token):
    for bad in (
        {"type": "teleport"},
        {"id": "not-a-uuid"},
        {"lat": 123.0},
        {"at": "2027-03-02T07:00:00"},  # no time zone
        {"secret": "x"},
    ):
        r = _send(token, [_punch("checkIn", _today(7), **bad)])
        assert r.status_code == 422, bad


def test_a_batch_has_a_size_limit(token):
    many = [_punch("checkIn", _today(7)) for _ in range(501)]
    assert _send(token, many).status_code == 422


def test_report_lists_the_day(token, capsys):
    from app.cli import main as cli

    p = _punch("checkIn", _today(7))
    _send(token, [p])
    day = (_today(7) + timedelta(hours=4)).date().isoformat()
    assert cli(["report", "--day", day]) == 0
    assert "Asha" in capsys.readouterr().out


class TestOnePhonePerSession:
    """Checked in on one phone means finishing on that phone."""

    def _open(self, token: str, worker: str = "w1") -> dict:
        day = (_today(7) + timedelta(hours=4)).date().isoformat()
        r = client.get(
            f"/workers/{worker}/open-session",
            params={"day": day},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 200
        return r.json()

    def test_another_phone_sees_the_open_session(self, token):
        _send(token, [_punch("checkIn", _today(7), via="gate")])
        own = _token("Asha's phone")
        assert self._open(own) == {"open": True, "onThisPhone": False}
        assert self._open(token) == {"open": True, "onThisPhone": True}
        assert self._open(own, worker="someone-else")["open"] is False

    def test_after_check_out_any_phone_may_start(self, token):
        _send(
            token,
            [_punch("checkIn", _today(7), via="gate"), _punch("checkOut", _today(12), via="gate")],
        )
        assert self._open(_token("Asha's phone"))["open"] is False

    def test_a_session_moved_to_another_phone_is_flagged(self, token):
        _send(token, [_punch("checkIn", _today(7), via="gate")])
        out = _punch("checkOut", _today(16), via="ownPhone")
        flags = _send(_token("Asha's phone"), [out]).json()["flags"][out["id"]]
        assert "other_phone" in flags

    def test_automatic_punches_do_not_count_as_another_phone(self, token):
        _send(token, [_punch("checkIn", _today(7), via="gate")])
        # A supervisor's correction, sent from the supervisor's phone.
        fix = _punch("checkOut", _today(16), corrected=True, distance=0.0)
        r = _send(_token("Supervisor"), [fix]).json()
        assert fix["id"] not in r["flags"]

    def test_the_question_needs_a_paired_phone_and_a_real_day(self, token):
        assert (
            client.get("/workers/w1/open-session", params={"day": "2027-03-02"}).status_code == 401
        )
        r = client.get(
            "/workers/w1/open-session",
            params={"day": "yesterday"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert r.status_code == 422

    def test_via_must_be_known(self, token):
        r = _send(token, [_punch("checkIn", _today(7), via="laptop")])
        assert r.status_code == 422
