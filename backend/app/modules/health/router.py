"""Is the server up, is it ready, and which app versions does it accept.

GET /health              liveness + server clock (the phone compares clocks)
GET /v1/health/ready     database reachable and migrated to the newest revision
GET /v1/meta/version     server version, oldest app version still accepted
"""

from datetime import UTC, datetime

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from app.core.config import SERVICE, VERSION, get_settings
from app.core.db import connect, schema_status

router = APIRouter(tags=["health"])


class Health(BaseModel):
    status: str
    service: str
    version: str
    serverTime: str


class Ready(BaseModel):
    ready: bool
    database: str
    migrations: str | None = None


class Meta(BaseModel):
    service: str
    version: str
    apiVersions: list[str]
    minAppVersion: str


@router.get("/health", response_model=Health)
def health() -> Health:
    """Says the server is up, and what time it thinks it is.

    The phone compares serverTime with its own clock; a large gap is the
    first sign of a tampered clock.
    """
    return Health(
        status="ok",
        service=SERVICE,
        version=VERSION,
        serverTime=datetime.now(UTC).isoformat(),
    )


@router.get("/v1/health/ready", response_model=Ready, responses={503: {"model": Ready}})
def ready() -> JSONResponse:
    """200 only when the database answers and is at the newest migration."""
    try:
        conn = connect()
        try:
            conn.execute("SELECT 1").fetchone()
        finally:
            conn.close()
        current, head = schema_status()
    except Exception:  # noqa: BLE001 - any failure here means "not ready"
        body = Ready(ready=False, database="unreachable")
        return JSONResponse(body.model_dump(), status_code=503)
    ok = current == head
    body = Ready(ready=ok, database="ok", migrations="current" if ok else "behind")
    return JSONResponse(body.model_dump(), status_code=200 if ok else 503)


@router.get("/v1/meta/version", response_model=Meta)
def meta() -> Meta:
    return Meta(
        service=SERVICE,
        version=VERSION,
        apiVersions=["v1"],
        minAppVersion=get_settings().min_app_version,
    )
