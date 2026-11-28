import pytest

from app.core.db import migrate
from app.modules.devices.service import limiter


@pytest.fixture(autouse=True)
def fresh_db(tmp_path, monkeypatch):
    """Every test gets its own migrated database and fresh pairing limits."""
    path = tmp_path / "test.db"
    monkeypatch.setenv("TRUSTPUNCH_DB", str(path))
    migrate(str(path))
    limiter.reset()
    yield path
