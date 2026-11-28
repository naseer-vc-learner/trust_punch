import pytest

from app.security import limiter


@pytest.fixture(autouse=True)
def fresh_db(tmp_path, monkeypatch):
    """Every test gets its own empty server database and pairing limits."""
    monkeypatch.setenv("TRUSTPUNCH_DB", str(tmp_path / "test.db"))
    limiter.reset()
    yield
