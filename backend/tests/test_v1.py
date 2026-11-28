"""/v1 routes, and what every response carries (errors, ids, headers)."""

from datetime import UTC, datetime

from fastapi.testclient import TestClient

from app.core.db import connect
from app.main import app, create_app
from app.modules.devices.service import new_pair_code

client = TestClient(app)


def _code() -> str:
    conn = connect()
    try:
        return new_pair_code(conn)
    finally:
        conn.close()


def _pair(path: str = "/v1/devices/pair") -> str:
    r = client.post(path, json={"code": _code(), "deviceName": "Gate", "platform": "android"})
    assert r.status_code == 200, r.text
    return r.json()["token"]


class TestVersionedRoutes:
    def test_pair_and_identify_under_v1(self):
        token = _pair()
        me = client.get("/v1/devices/me", headers={"Authorization": f"Bearer {token}"})
        assert me.status_code == 200
        assert me.json()["name"] == "Gate"

    def test_old_paths_still_work_for_todays_app(self):
        token = _pair("/devices/pair")
        for path in ("/devices/me", "/v1/devices/me"):
            r = client.get(path, headers={"Authorization": f"Bearer {token}"})
            assert r.status_code == 200, path

    def test_upload_under_v1(self):
        token = _pair()
        r = client.post(
            "/v1/punches/batch",
            headers={"Authorization": f"Bearer {token}"},
            json={"sentAt": datetime.now(UTC).isoformat(), "punches": []},
        )
        assert r.status_code == 200
        assert r.json()["accepted"] == []

    def test_api_description_lists_only_v1_and_health(self):
        schema = create_app().openapi()
        paths = set(schema["paths"])
        assert "/v1/devices/pair" in paths
        assert "/v1/punches/batch" in paths
        assert "/devices/pair" not in paths
        assert all(p.startswith("/v1/") or p == "/health" for p in paths)


class TestHealth:
    def test_ready_when_migrated(self):
        r = client.get("/v1/health/ready")
        assert r.status_code == 200
        assert r.json() == {"ready": True, "database": "ok", "migrations": "current"}

    def test_not_ready_when_the_database_is_behind(self, tmp_path, monkeypatch):
        monkeypatch.setenv("TRUSTPUNCH_DB", str(tmp_path / "empty.db"))
        r = client.get("/v1/health/ready")
        assert r.status_code == 503
        assert r.json()["ready"] is False

    def test_meta_reports_minimum_app_version(self, monkeypatch):
        monkeypatch.setenv("TRUSTPUNCH_MIN_APP_VERSION", "1.4.0")
        body = client.get("/v1/meta/version").json()
        assert body["minAppVersion"] == "1.4.0"
        assert body["apiVersions"] == ["v1"]


class TestErrors:
    def test_unknown_route_is_problem_json(self):
        r = client.get("/v1/nope")
        assert r.status_code == 404
        assert r.headers["content-type"].startswith("application/problem+json")
        body = r.json()
        assert body["status"] == 404 and body["title"] == "Not Found"
        assert body["requestId"] == r.headers["x-request-id"]

    def test_validation_error_lists_fields_without_echoing_values(self):
        r = client.post(
            "/v1/devices/pair",
            json={"code": "12ab56", "deviceName": "Secret Name", "platform": "ios"},
        )
        assert r.status_code == 422
        body = r.json()
        assert isinstance(body["detail"], str)
        assert body["errors"][0]["loc"] == ["body", "code"]
        assert "12ab56" not in r.text and "Secret Name" not in r.text

    def test_missing_token_says_bearer(self):
        r = client.get("/v1/devices/me")
        assert r.status_code == 401
        assert r.json()["detail"] == "Not paired"
        assert r.headers["www-authenticate"] == "Bearer"

    def test_too_large_body_is_refused_before_reading(self):
        r = client.post(
            "/v1/punches/batch",
            content=b"x",
            headers={"content-length": "999999999", "content-type": "application/json"},
        )
        assert r.status_code == 413
        assert r.json()["detail"] == "Request too large"


class TestEveryResponse:
    def test_gets_a_request_id(self):
        r = client.get("/health")
        assert len(r.headers["x-request-id"]) >= 8

    def test_keeps_a_sane_incoming_request_id(self):
        r = client.get("/health", headers={"X-Request-ID": "phone-abc-12345"})
        assert r.headers["x-request-id"] == "phone-abc-12345"

    def test_replaces_a_hostile_request_id(self):
        r = client.get("/health", headers={"X-Request-ID": "x\r\nSet-Cookie: a=b"})
        assert r.headers["x-request-id"] != "x\r\nSet-Cookie: a=b"
        assert "\n" not in r.headers["x-request-id"]

    def test_has_security_headers(self):
        h = client.get("/health").headers
        assert h["x-content-type-options"] == "nosniff"
        assert h["x-frame-options"] == "DENY"
        assert h["cache-control"] == "no-store"
        assert h["referrer-policy"] == "no-referrer"
        assert "default-src 'none'" in h["content-security-policy"]
