import pytest

from app.core.db import dispose_engines, migrate
from app.modules.auth.service import ip_limiter
from app.modules.devices.service import limiter


@pytest.fixture(autouse=True)
def fresh_db(tmp_path, monkeypatch):
    """Every test gets its own migrated database and fresh rate limits."""
    path = tmp_path / "test.db"
    monkeypatch.setenv("TRUSTPUNCH_DB", str(path))
    migrate(str(path))
    limiter.reset()
    ip_limiter.reset()
    yield path
    dispose_engines()
