"""HTTP for signing in and out, refreshing, and the signed-in user.

POST /v1/auth/login       username + password -> tokens
POST /v1/auth/refresh     refresh token -> new tokens (the old one is spent)
POST /v1/auth/logout      end this session (?everywhere=true: all of them)
GET  /v1/me               who am I, my roles, and the permission codes I hold
POST /v1/me/password      change password (needs the current one)
"""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

from app.core.access import public
from app.core.config import DEFAULT_TENANT_ID
from app.core.db import Conn
from app.core.schemas import Strict
from app.modules.roles import service as roles
from app.modules.users import service as users
from app.rbac import policy

from . import service
from .deps import CurrentUser

router = APIRouter(tags=["auth"])

_UNAUTHORIZED = {"WWW-Authenticate": "Bearer"}
_BAD_LOGIN = "Wrong username or password, or the account is locked for a while"
_SLOW_DOWN = "Too many failed attempts from this address; try again later"


class LoginRequest(Strict):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=users.MAX_PASSWORD)
    tenantId: str = Field(default=DEFAULT_TENANT_ID, min_length=36, max_length=36)


class RefreshRequest(Strict):
    refreshToken: str = Field(min_length=10, max_length=200)


class PasswordChange(Strict):
    currentPassword: str = Field(min_length=1, max_length=users.MAX_PASSWORD)
    newPassword: str = Field(min_length=1, max_length=users.MAX_PASSWORD)


class TokenPair(BaseModel):
    tokenType: str = "Bearer"
    accessToken: str
    accessExpiresAt: str
    refreshToken: str
    refreshExpiresAt: str


class Identity(BaseModel):
    id: str
    tenantId: str
    username: str
    displayName: str


class RoleHeld(BaseModel):
    role: str
    scopeType: str
    scopeId: str


class Me(Identity):
    roles: list[RoleHeld]
    # Every permission that reaches anything, for showing and hiding parts of
    # the app. The server still checks each request; this only shapes the UI.
    permissions: list[str]


class LoginResponse(TokenPair):
    user: Identity


def _pair(t: service.Tokens) -> dict[str, str]:
    return {
        "accessToken": t.access_token,
        "accessExpiresAt": t.access_expires_at,
        "refreshToken": t.refresh_token,
        "refreshExpiresAt": t.refresh_expires_at,
    }


def _identity(p: service.Principal) -> Identity:
    return Identity(
        id=p.user_id, tenantId=p.tenant_id, username=p.username, displayName=p.display_name
    )


def _client(request: Request) -> str:
    return request.client.host if request.client else "unknown"


@router.post("/auth/login", response_model=LoginResponse, dependencies=[Depends(public)])
def login(body: LoginRequest, request: Request, conn: Conn) -> LoginResponse:
    try:
        tokens, principal = service.login(
            conn, body.tenantId, body.username, body.password, _client(request)
        )
    except service.TooManyAttempts:
        raise HTTPException(429, _SLOW_DOWN, headers={"Retry-After": "900"}) from None
    except service.BadCredentials:
        raise HTTPException(401, _BAD_LOGIN, headers=_UNAUTHORIZED) from None
    return LoginResponse(**_pair(tokens), user=_identity(principal))


@router.post("/auth/refresh", response_model=TokenPair, dependencies=[Depends(public)])
def refresh(body: RefreshRequest, conn: Conn) -> TokenPair:
    try:
        tokens = service.refresh(conn, body.refreshToken)
    except service.InvalidToken:
        raise HTTPException(401, "Session expired; sign in again", headers=_UNAUTHORIZED) from None
    return TokenPair(**_pair(tokens))


@router.post("/auth/logout", status_code=204)
def logout(
    user: CurrentUser,
    conn: Conn,
    everywhere: Annotated[bool, Query()] = False,
) -> Response:
    service.logout(conn, user, everywhere)
    return Response(status_code=204)


@router.get("/me", response_model=Me)
def me(user: CurrentUser, conn: Conn) -> Me:
    actor = roles.actor_for(conn, user.user_id, user.tenant_id)
    return Me(
        **_identity(user).model_dump(),
        roles=[
            RoleHeld(role=g.role, scopeType=g.scope_type, scopeId=g.scope_id) for g in actor.grants
        ],
        permissions=policy.permissions_of(actor),
    )


@router.post("/me/password", status_code=204)
def change_password(
    body: PasswordChange, user: CurrentUser, request: Request, conn: Conn
) -> Response:
    try:
        service.change_password(
            conn, user, body.currentPassword, body.newPassword, _client(request)
        )
    except service.TooManyAttempts:
        raise HTTPException(429, _SLOW_DOWN, headers={"Retry-After": "900"}) from None
    except service.BadCredentials:
        raise HTTPException(403, "The current password is not right") from None
    except users.WeakPassword as e:
        raise HTTPException(422, "Choose a stronger password: " + "; ".join(e.reasons)) from None
    return Response(status_code=204)
