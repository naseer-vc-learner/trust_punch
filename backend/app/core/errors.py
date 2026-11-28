"""Every error leaves the server as RFC 9457 problem details:

    {"type": "about:blank", "title": "Forbidden", "status": 403,
     "detail": "This phone is blocked", "requestId": "..."}

`detail` is always a human-readable string (the phone shows it as-is).
Validation errors add `errors`: where and what, never the rejected value
itself, which could be someone's personal data. Unexpected failures return a
bare 500 with the request id, never a stack trace.
"""

import logging
from collections.abc import Mapping
from http import HTTPStatus

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

PROBLEM_JSON = "application/problem+json"

log = logging.getLogger("trustpunch.errors")


def problem(
    status: int,
    detail: str,
    request: Request | None = None,
    headers: Mapping[str, str] | None = None,
    **extra: object,
) -> JSONResponse:
    try:
        title = HTTPStatus(status).phrase
    except ValueError:
        title = "Error"
    body: dict[str, object] = {
        "type": "about:blank",
        "title": title,
        "status": status,
        "detail": detail,
    }
    if request is not None and getattr(request.state, "request_id", None):
        body["requestId"] = request.state.request_id
    body.update(extra)
    return JSONResponse(body, status_code=status, headers=headers, media_type=PROBLEM_JSON)


def _http_error(request: Request, exc: Exception) -> JSONResponse:
    if not isinstance(exc, StarletteHTTPException):
        return _unexpected(request, exc)
    detail = exc.detail if isinstance(exc.detail, str) else HTTPStatus(exc.status_code).phrase
    return problem(exc.status_code, detail, request, headers=exc.headers)


def _validation_error(request: Request, exc: Exception) -> JSONResponse:
    if not isinstance(exc, RequestValidationError):
        return _unexpected(request, exc)
    errors = [
        {"loc": list(e.get("loc", ())), "msg": e.get("msg", ""), "type": e.get("type", "")}
        for e in exc.errors()
    ]
    return problem(422, "The request is not valid", request, errors=errors)


def _unexpected(request: Request, exc: Exception) -> JSONResponse:
    log.error(
        "unhandled error",
        exc_info=exc,
        extra={"request_id": getattr(request.state, "request_id", None)},
    )
    return problem(500, "Something went wrong on the server", request)


def install(app: FastAPI) -> None:
    app.add_exception_handler(StarletteHTTPException, _http_error)
    app.add_exception_handler(RequestValidationError, _validation_error)
    app.add_exception_handler(Exception, _unexpected)
