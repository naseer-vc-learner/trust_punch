"""TrustPunch API: the app factory.

The phone stays the place where attendance happens (face, liveness, GPS);
the server keeps its own copy, stores each punch once, re-checks what it can
and, step by step, becomes the source of truth for people, sites, rules and
approvals. Only the "connected" app talks to it; the offline demo app never
does. See docs/CONNECTED_PLATFORM_PLAN.md.

Every module's routes are served under /v1. The unversioned paths the
current app uses (/devices/pair, /punches/batch, ...) are served too, hidden
from the API description, until the app moves to /v1 (plan, Day 11).
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.core import errors, http
from app.core.access import verify_routes
from app.core.config import VERSION, get_settings
from app.core.db import dispose_engines, migrate
from app.core.logging import configure_logging
from app.modules.attendance.router import router as attendance_router
from app.modules.auth.router import router as auth_router
from app.modules.devices.router import router as devices_router
from app.modules.health.router import router as health_router
from app.modules.roles.router import router as roles_router

V1 = "/v1"
# Served at both the old path and /v1 until the app moves (plan, Day 11).
_LEGACY_ROUTERS = (devices_router, attendance_router)


@asynccontextmanager
async def _lifespan(_: FastAPI) -> AsyncIterator[None]:
    migrate()
    yield
    dispose_engines()


def create_app() -> FastAPI:
    configure_logging()
    debug = get_settings().debug
    app = FastAPI(
        title="TrustPunch API",
        version=VERSION,
        # The docs describe every endpoint to anyone who can reach the server,
        # so they exist only when a developer turns them on explicitly.
        docs_url="/docs" if debug else None,
        redoc_url=None,
        openapi_url="/openapi.json" if debug else None,
        lifespan=_lifespan,
    )
    errors.install(app)
    http.install(app)

    app.include_router(health_router)
    app.include_router(auth_router, prefix=V1)
    app.include_router(roles_router, prefix=V1)
    for router in _LEGACY_ROUTERS:
        app.include_router(router, prefix=V1)
        app.include_router(router, include_in_schema=False)
    # Deny by default: refuse to start if any route doesn't say who may call it.
    verify_routes(app)
    return app


app = create_app()
