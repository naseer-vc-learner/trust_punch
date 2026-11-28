"""Identifiers: UUIDv7 (RFC 9562), time-ordered so new rows sort last and
indexes stay compact, with 74 random bits so they cannot be guessed."""

import secrets
import time
import uuid


def new_id() -> str:
    native = getattr(uuid, "uuid7", None)  # Python 3.14+
    if native is not None:
        return str(native())
    ms = time.time_ns() // 1_000_000
    raw = bytearray(ms.to_bytes(6, "big") + secrets.token_bytes(10))
    raw[6] = (raw[6] & 0x0F) | 0x70  # version 7
    raw[8] = (raw[8] & 0x3F) | 0x80  # RFC 9562 variant
    return str(uuid.UUID(bytes=bytes(raw)))
