"""FastAPI dependencies other modules may use: who is calling."""

import sqlite3
from typing import Annotated

from fastapi import Depends, Header, HTTPException

from app.core.db import get_db

from . import service

Db = Annotated[sqlite3.Connection, Depends(get_db)]


def current_device(db: Db, authorization: Annotated[str | None, Header()] = None) -> sqlite3.Row:
    """The paired, unblocked device making this request."""
    try:
        return service.authenticate(db, authorization)
    except service.NotPaired:
        raise HTTPException(401, "Not paired", headers={"WWW-Authenticate": "Bearer"}) from None
    except service.Blocked:
        raise HTTPException(403, "This phone is blocked") from None


Device = Annotated[sqlite3.Row, Depends(current_device)]
