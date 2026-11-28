"""HTTP middleware applied to every request.

- Refuses bodies over the size limit before reading them.
- Gives every request an id (``X-Request-ID``), echoed in the response and in
  error bodies, so a phone's error can be matched to the server's log line.
- Adds security headers. The API serves JSON only, so the policy is "nothing
  may load, frame or sniff"; the debug-only /docs page is the one exception.
- Writes one access-log line per request: method, route template, status,
  duration. Nothing from the path values, query, headers or body.
"""

import logging
import re
import time
import uuid

from fastapi import FastAPI, Request
from starlette.responses import Response

from .config import get_settings
from .errors import problem

access_log = logging.getLogger("trustpunch.access")

_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{8,64}$")

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
}


def install(app: FastAPI) -> None:
    @app.middleware("http")
    async def per_request(request: Request, call_next) -> Response:
        started = time.perf_counter()
        incoming = request.headers.get("x-request-id", "")
        request_id = incoming if _REQUEST_ID.match(incoming) else uuid.uuid4().hex
        request.state.request_id = request_id

        length = request.headers.get("content-length")
        limit = get_settings().max_body_bytes
        if length is not None and (not length.isdigit() or int(length) > limit):
            response: Response = problem(413, "Request too large", request)
        else:
            response = await call_next(request)

        response.headers["X-Request-ID"] = request_id
        for name, value in SECURITY_HEADERS.items():
            if name == "Content-Security-Policy" and request.url.path.startswith("/docs"):
                continue
            response.headers.setdefault(name, value)

        route = request.scope.get("route")
        access_log.info(
            "request",
            extra={
                "request_id": request_id,
                "method": request.method,
                "route": getattr(route, "path", None) or "unmatched",
                "status": response.status_code,
                "duration_ms": round((time.perf_counter() - started) * 1000, 1),
            },
        )
        return response
