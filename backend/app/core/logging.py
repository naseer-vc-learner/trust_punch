"""Structured logs: one JSON object per line, on stderr.

Logs carry the route *template* (``/v1/workers/{worker_id}/open-session``),
never the filled-in path, query string, headers or bodies, so no name,
employee id, location or token is ever written to a log.
"""

import json
import logging
import sys
from datetime import UTC, datetime

# Fields a log call may add with ``extra={...}``; anything else is dropped.
_ALLOWED_EXTRA = ("request_id", "method", "route", "status", "duration_ms")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key in _ALLOWED_EXTRA:
            value = getattr(record, key, None)
            if value is not None:
                entry[key] = value
        if record.exc_info:
            entry["error"] = record.exc_info[0].__name__ if record.exc_info[0] else "Exception"
        return json.dumps(entry, separators=(",", ":"))


def configure_logging(level: int = logging.INFO) -> None:
    logger = logging.getLogger("trustpunch")
    if any(getattr(h, "_trustpunch", False) for h in logger.handlers):
        return
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(JsonFormatter())
    handler._trustpunch = True  # type: ignore[attr-defined]
    logger.addHandler(handler)
    logger.setLevel(level)
    logger.propagate = False
