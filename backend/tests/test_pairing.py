from fastapi.testclient import TestClient

from app.db import connect
from app.main import app

client = TestClient(app)


def _code() -> str:
    conn = connect()
    try:
        from app.security import new_pair_code

        return new_pair_code(conn)
    finally:
        conn.close()


def _pair(code: str, name: str = "Gate phone"):
    return client.post(
        "/devices/pair",
        json={"code": code, "deviceName": name, "platform": "ios"},
    )


def test_a_valid_code_pairs_once():
    code = _code()
    first = _pair(code)
    assert first.status_code == 200
    body = first.json()
    assert body["deviceId"] and len(body["token"]) >= 40

    me = client.get("/devices/me", headers={"Authorization": f"Bearer {body['token']}"})
    assert me.status_code == 200
    assert me.json()["name"] == "Gate phone"

    # Used: it cannot pair a second phone.
    assert _pair(code).status_code == 403


def test_a_wrong_code_is_refused():
    _code()
    assert _pair("000000").status_code in (403,)


def test_the_token_is_not_stored():
    token = _pair(_code()).json()["token"]
    conn = connect()
    try:
        stored = conn.execute("SELECT token_hash FROM devices").fetchone()[0]
    finally:
        conn.close()
    assert token not in stored
    assert len(stored) == 64  # SHA-256 hex


def test_guessing_closes_open_codes():
    code = _code()
    for guess in range(5):
        _pair(f"{guess:06d}" if f"{guess:06d}" != code else "999999")
    # The real code no longer works after five wrong guesses...
    assert _pair(code).status_code in (403, 429)


def test_one_address_is_slowed_down():
    for guess in range(5):
        _pair(f"{guess:06d}")
    assert _pair("123456").status_code == 429


def test_bad_input_is_refused():
    assert client.post("/devices/pair", json={"code": "12ab56", "deviceName": "x",
                                              "platform": "ios"}).status_code == 422
    assert client.post("/devices/pair", json={"code": "123456", "deviceName": "x",
                                              "platform": "ios",
                                              "admin": True}).status_code == 422


def test_without_a_token_nothing_is_reachable():
    assert client.get("/devices/me").status_code == 401
    assert client.get("/devices/me",
                      headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.post("/punches/batch",
                       json={"sentAt": "2027-03-02T07:00:00Z",
                             "punches": []}).status_code == 401


def test_a_blocked_phone_is_refused():
    token = _pair(_code()).json()["token"]
    from app.cli import main as cli

    conn = connect()
    device_id = conn.execute("SELECT id FROM devices").fetchone()[0]
    conn.close()
    assert cli(["block", device_id]) == 0
    r = client.get("/devices/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 403
