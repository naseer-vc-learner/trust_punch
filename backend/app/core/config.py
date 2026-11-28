"""Every setting the server reads, in one place, from TRUSTPUNCH_* variables.

    TRUSTPUNCH_DB               database file (default: backend/data/trustpunch.db)
    TRUSTPUNCH_DEBUG=1          turn on /docs and /openapi.json (never on a shared network)
    TRUSTPUNCH_MIN_APP_VERSION  oldest app version the server still accepts (default 0.0.0)
    TRUSTPUNCH_MAX_BODY_BYTES   largest request body (default 2 MB)

Settings are read when asked for, not once at import, so a test (or the CLI)
that points TRUSTPUNCH_DB somewhere else is honoured straight away.
"""

from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

VERSION = "0.3.0"
SERVICE = "trustpunch-api"

# The one company until multi-tenant sign-up exists (made by migration 0002).
DEFAULT_TENANT_ID = "00000000-0000-7000-8000-000000000001"

BACKEND_DIR = Path(__file__).resolve().parents[2]
_DEFAULT_DB = BACKEND_DIR / "data" / "trustpunch.db"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="TRUSTPUNCH_", extra="ignore")

    db: str = str(_DEFAULT_DB)
    debug: bool = False
    min_app_version: str = Field(default="0.0.0", pattern=r"^\d+\.\d+\.\d+$")
    max_body_bytes: int = Field(default=2_000_000, ge=1_000, le=50_000_000)


def get_settings() -> Settings:
    return Settings()
