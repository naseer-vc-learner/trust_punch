"""Signing in, refreshing, signing out, lockout, and password changes."""

import sqlite3
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from app.core.config import DEFAULT_TENANT_ID
from app.core.db import connect, engine
from app.main import app
from app.modules.devices.service import new_pair_code
from app.modules.users import service as users

client = TestClient(app)

PASSWORD = "correct horse battery"


def _user(username: str = "asha", password: str = PASSWORD) -> str:
    with engine().connect() as conn:
        user_id = users.create_user(conn, DEFAULT_TENANT_ID, username, "Asha K", password)
        conn.commit()
    return user_id


def _login(username: str = "asha", password: str = PASSWORD):
    return client.post("/v1/auth/login", json={"username": username, "password": password})


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _db(fresh_db) -> sqlite3.Connection:
    conn = sqlite3.connect(fresh_db)
    conn.row_factory = sqlite3.Row
    return conn


class TestLogin:
    def test_signs_in_and_knows_who_you_are(self):
        user_id = _user()
        r = _login()
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["tokenType"] == "Bearer"
        assert body["accessToken"].startswith("tp_at_")
        assert body["refreshToken"].startswith("tp_rt_")
        assert body["user"] == {
            "id": user_id,
            "tenantId": DEFAULT_TENANT_ID,
            "username": "asha",
            "displayName": "Asha K",
        }
        me = client.get("/v1/me", headers=_auth(body["accessToken"]))
        assert me.status_code == 200
        assert me.json()["username"] == "asha"

    def test_username_is_case_insensitive(self):
        _user()
        assert _login("  ASHA ").status_code == 200

    def test_wrong_password_and_unknown_user_look_the_same(self):
        _user()
        wrong = _login(password="not the password")
        unknown = _login(username="nobody")
        assert wrong.status_code == unknown.status_code == 401
        assert wrong.json()["detail"] == unknown.json()["detail"]
        assert wrong.headers["www-authenticate"] == "Bearer"

    def test_tokens_and_passwords_are_stored_hashed(self, fresh_db):
        _user()
        body = _login().json()
        db = _db(fresh_db)
        stored = db.execute("SELECT access_hash, refresh_hash FROM sessions").fetchone()
        user = db.execute("SELECT password_hash FROM users").fetchone()
        db.close()
        assert body["accessToken"] not in stored["access_hash"]
        assert len(stored["access_hash"]) == len(stored["refresh_hash"]) == 64
        assert user["password_hash"].startswith("$argon2id$")
        assert PASSWORD not in user["password_hash"]

    def test_unknown_fields_and_huge_passwords_are_refused(self):
        assert (
            client.post(
                "/v1/auth/login", json={"username": "a", "password": "b", "admin": True}
            ).status_code
            == 422
        )
        assert _login(password="x" * 500).status_code == 422


class TestLockout:
    def test_five_wrong_passwords_lock_the_account(self, fresh_db):
        _user()
        for _ in range(5):
            assert _login(password="wrong password!").status_code == 401
        # Locked: even the right password is refused, with the same answer.
        locked = _login()
        assert locked.status_code == 401
        db = _db(fresh_db)
        row = db.execute("SELECT failed_logins, locked_until FROM users").fetchone()
        db.close()
        assert row["failed_logins"] == 5 and row["locked_until"] is not None

    def test_the_lock_expires(self, fresh_db):
        _user()
        for _ in range(5):
            _login(password="wrong password!")
        past = (datetime.now(UTC) - timedelta(minutes=1)).isoformat()
        db = _db(fresh_db)
        db.execute("UPDATE users SET locked_until = ?", (past,))
        db.commit()
        db.close()
        assert _login().status_code == 200

    def test_a_good_login_resets_the_count(self, fresh_db):
        _user()
        for _ in range(4):
            _login(password="wrong password!")
        assert _login().status_code == 200
        db = _db(fresh_db)
        assert db.execute("SELECT failed_logins FROM users").fetchone()[0] == 0
        db.close()

    def test_one_address_is_slowed_down_across_usernames(self):
        for i in range(20):
            _login(username=f"guess{i}", password="whatever password")
        r = _login(username="guess-more", password="whatever password")
        assert r.status_code == 429
        assert r.headers["retry-after"] == "900"


class TestRefresh:
    def test_refresh_gives_a_new_pair_and_spends_the_old_token(self):
        _user()
        first = _login().json()
        r = client.post("/v1/auth/refresh", json={"refreshToken": first["refreshToken"]})
        assert r.status_code == 200
        second = r.json()
        assert second["refreshToken"] != first["refreshToken"]
        assert client.get("/v1/me", headers=_auth(second["accessToken"])).status_code == 200
        # The old access token died with its rotated session.
        assert client.get("/v1/me", headers=_auth(first["accessToken"])).status_code == 401

    def test_reusing_a_spent_refresh_token_ends_the_whole_family(self):
        _user()
        first = _login().json()
        second = client.post(
            "/v1/auth/refresh", json={"refreshToken": first["refreshToken"]}
        ).json()
        # Someone replays the first refresh token: refused, and the family ends.
        replay = client.post("/v1/auth/refresh", json={"refreshToken": first["refreshToken"]})
        assert replay.status_code == 401
        assert client.get("/v1/me", headers=_auth(second["accessToken"])).status_code == 401
        assert (
            client.post(
                "/v1/auth/refresh", json={"refreshToken": second["refreshToken"]}
            ).status_code
            == 401
        )

    def test_an_expired_refresh_token_is_refused(self, fresh_db):
        _user()
        body = _login().json()
        db = _db(fresh_db)
        db.execute(
            "UPDATE sessions SET refresh_expires_at = ?",
            ((datetime.now(UTC) - timedelta(seconds=1)).isoformat(),),
        )
        db.commit()
        db.close()
        r = client.post("/v1/auth/refresh", json={"refreshToken": body["refreshToken"]})
        assert r.status_code == 401

    def test_an_access_token_is_not_a_refresh_token(self):
        _user()
        body = _login().json()
        r = client.post("/v1/auth/refresh", json={"refreshToken": body["accessToken"]})
        assert r.status_code == 401


class TestAccess:
    def test_an_expired_access_token_is_refused(self, fresh_db):
        _user()
        body = _login().json()
        db = _db(fresh_db)
        db.execute(
            "UPDATE sessions SET access_expires_at = ?",
            ((datetime.now(UTC) - timedelta(seconds=1)).isoformat(),),
        )
        db.commit()
        db.close()
        assert client.get("/v1/me", headers=_auth(body["accessToken"])).status_code == 401

    def test_device_tokens_and_user_tokens_do_not_mix(self):
        _user()
        access = _login().json()["accessToken"]
        conn = connect()
        code = new_pair_code(conn)
        conn.close()
        device = client.post(
            "/v1/devices/pair", json={"code": code, "deviceName": "Gate", "platform": "ios"}
        ).json()["token"]
        assert client.get("/v1/me", headers=_auth(device)).status_code == 401
        assert client.get("/v1/devices/me", headers=_auth(access)).status_code == 401

    def test_a_disabled_user_is_cut_off_at_once(self):
        _user()
        body = _login().json()
        with engine().connect() as conn:
            users.set_disabled(conn, users.find(conn, DEFAULT_TENANT_ID, "asha")["id"], True)
            conn.commit()
        assert client.get("/v1/me", headers=_auth(body["accessToken"])).status_code == 401
        assert (
            client.post("/v1/auth/refresh", json={"refreshToken": body["refreshToken"]}).status_code
            == 401
        )
        assert _login().status_code == 401


class TestLogout:
    def test_logout_ends_this_session_only(self):
        _user()
        phone = _login().json()
        laptop = _login().json()
        r = client.post("/v1/auth/logout", headers=_auth(phone["accessToken"]))
        assert r.status_code == 204
        assert client.get("/v1/me", headers=_auth(phone["accessToken"])).status_code == 401
        assert client.get("/v1/me", headers=_auth(laptop["accessToken"])).status_code == 200

    def test_logout_everywhere(self):
        _user()
        phone = _login().json()
        laptop = _login().json()
        client.post("/v1/auth/logout?everywhere=true", headers=_auth(phone["accessToken"]))
        assert client.get("/v1/me", headers=_auth(laptop["accessToken"])).status_code == 401


class TestPasswordChange:
    NEW = "a much longer new passphrase"

    def _change(self, token: str, current: str, new: str):
        return client.post(
            "/v1/me/password",
            headers=_auth(token),
            json={"currentPassword": current, "newPassword": new},
        )

    def test_change_signs_out_other_sessions_but_not_this_one(self):
        _user()
        this = _login().json()
        other = _login().json()
        assert self._change(this["accessToken"], PASSWORD, self.NEW).status_code == 204
        assert client.get("/v1/me", headers=_auth(this["accessToken"])).status_code == 200
        assert client.get("/v1/me", headers=_auth(other["accessToken"])).status_code == 401
        assert _login(password=PASSWORD).status_code == 401
        assert _login(password=self.NEW).status_code == 200

    def test_needs_the_current_password(self):
        _user()
        token = _login().json()["accessToken"]
        assert self._change(token, "not my password", self.NEW).status_code == 403

    @pytest.mark.parametrize(
        "weak",
        ["short", "password1234", "aaaaaaaaaaaaaaa", "123456789012345", "asha-is-great-2026"],
    )
    def test_weak_passwords_are_refused(self, weak):
        _user()
        token = _login().json()["accessToken"]
        r = self._change(token, PASSWORD, weak)
        assert r.status_code == 422
        assert r.json()["detail"].startswith("Choose a stronger password")

    def test_the_same_password_again_is_refused(self):
        _user()
        token = _login().json()["accessToken"]
        assert self._change(token, PASSWORD, PASSWORD).status_code == 422


class TestCreateAdminCommand:
    def test_creates_a_user_from_typed_passwords(self, monkeypatch, capsys):
        from app import cli

        answers = iter([PASSWORD, PASSWORD])
        monkeypatch.setattr(cli.getpass, "getpass", lambda _prompt: next(answers))
        assert cli.main(["create-admin", "--username", "Owner", "--display-name", "Owner"]) == 0
        assert "Created user owner" in capsys.readouterr().out
        assert _login("owner").status_code == 200

    def test_refuses_mismatched_or_weak_passwords(self, monkeypatch):
        from app import cli

        answers = iter([PASSWORD, PASSWORD + "x", "short", "short"])
        monkeypatch.setattr(cli.getpass, "getpass", lambda _prompt: next(answers))
        assert cli.main(["create-admin", "--username", "owner"]) == 1
        assert cli.main(["create-admin", "--username", "owner"]) == 1
        assert _login("owner").status_code == 401
