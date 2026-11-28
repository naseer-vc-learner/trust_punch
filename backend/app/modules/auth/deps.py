"""FastAPI dependencies other modules may use: the signed-in user."""

from typing import Annotated

from fastapi import Depends, Header, HTTPException

from app.core.db import Conn

from . import service
from .service import Principal


def current_user(conn: Conn, authorization: Annotated[str | None, Header()] = None) -> Principal:
    try:
        return service.authenticate(conn, authorization)
    except service.InvalidToken:
        raise HTTPException(
            401, "Sign in required", headers={"WWW-Authenticate": "Bearer"}
        ) from None


CurrentUser = Annotated[Principal, Depends(current_user)]
