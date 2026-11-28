from datetime import UTC, datetime

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_says_ok():
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["service"] == "trustpunch-api"


def test_health_reports_current_utc_time():
    body = client.get("/health").json()
    server_time = datetime.fromisoformat(body["serverTime"])
    assert server_time.tzinfo is not None
    assert abs((datetime.now(UTC) - server_time).total_seconds()) < 5


def test_docs_are_off_unless_debug():
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404
