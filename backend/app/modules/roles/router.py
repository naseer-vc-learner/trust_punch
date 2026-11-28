"""HTTP for roles.

GET    /v1/roles                               every role, its rank, scopes and permissions
GET    /v1/users/{user_id}/roles               a user's role assignments
POST   /v1/users/{user_id}/roles               grant a role (ranks below your own only)
DELETE /v1/users/{user_id}/roles/{assignment}  remove one
"""

from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Path, Response
from pydantic import BaseModel, Field
from sqlalchemy import RowMapping

from app.core.db import Conn
from app.core.schemas import Strict
from app.modules.auth.deps import CurrentUser
from app.modules.users import service as users
from app.rbac.permissions import ASSIGNABLE_AT, MATRIX, RANK, ROLES
from app.rbac.policy import Resource

from . import service
from .deps import NOT_FOUND, Access, require

router = APIRouter(tags=["roles"])

Id = Annotated[str, Path(min_length=1, max_length=64)]


class RoleInfo(BaseModel):
    role: str
    rank: int
    assignableAt: list[str]
    permissions: dict[str, str]


class Assignment(BaseModel):
    id: str
    role: str
    scopeType: str
    scopeId: str
    grantedBy: str | None
    createdAt: str


class GrantRequest(Strict):
    role: str = Field(min_length=1, max_length=32)
    scopeType: Literal["tenant", "region", "site", "team"]
    scopeId: str | None = Field(default=None, min_length=1, max_length=64)


def _assignment(r: RowMapping) -> Assignment:
    return Assignment(
        id=r["id"],
        role=r["role"],
        scopeType=r["scope_type"],
        scopeId=r["scope_id"],
        grantedBy=r["granted_by"],
        createdAt=r["created_at"],
    )


def _user_in_tenant(conn: Conn, access: Access, user_id: str) -> None:
    target = users.get(conn, user_id)
    if target is None or target["tenant_id"] != access.principal.tenant_id:
        raise HTTPException(404, NOT_FOUND)


@router.get("/roles", response_model=list[RoleInfo])
def list_roles(_: CurrentUser) -> list[RoleInfo]:
    """The role catalogue and matrix, so the app can explain who can do what."""
    return [
        RoleInfo(
            role=role,
            rank=RANK[role],
            assignableAt=sorted(ASSIGNABLE_AT[role]),
            permissions={p: cells[role] for p, cells in MATRIX.items() if role in cells},
        )
        for role in ROLES
    ]


@router.get("/users/{user_id}/roles", response_model=list[Assignment])
def user_roles(
    user_id: Id, access: Annotated[Access, require("users.read")], conn: Conn
) -> list[Assignment]:
    _user_in_tenant(conn, access, user_id)
    # Until people have sites and teams (Day 7) a user is reachable tenant-wide or as oneself.
    access.check(Resource(access.principal.tenant_id, owner_user_id=user_id))
    return [_assignment(r) for r in service.assignments(conn, user_id)]


@router.post("/users/{user_id}/roles", response_model=Assignment, status_code=201)
def grant_role(
    user_id: Id,
    body: GrantRequest,
    access: Annotated[Access, require("roles.assign")],
    conn: Conn,
) -> Assignment:
    _user_in_tenant(conn, access, user_id)
    try:
        assignment_id = service.grant(
            conn,
            access.actor,
            access.principal.tenant_id,
            user_id,
            body.role,
            body.scopeType,
            body.scopeId,
        )
    except service.InvalidGrant as e:
        raise HTTPException(422, str(e)) from None
    except service.NotAllowed as e:
        raise HTTPException(403, f"Not allowed: {e}") from None
    except service.NotFound:
        raise HTTPException(404, NOT_FOUND) from None
    row = next(r for r in service.assignments(conn, user_id) if r["id"] == assignment_id)
    return _assignment(row)


@router.delete("/users/{user_id}/roles/{assignment_id}", status_code=204)
def revoke_role(
    user_id: Id,
    assignment_id: Id,
    access: Annotated[Access, require("roles.assign")],
    conn: Conn,
) -> Response:
    try:
        service.revoke(conn, access.actor, access.principal.tenant_id, user_id, assignment_id)
    except service.NotFound:
        raise HTTPException(404, NOT_FOUND) from None
    except service.NotAllowed as e:
        raise HTTPException(403, f"Not allowed: {e}") from None
    except service.LastAdmin as e:
        raise HTTPException(409, str(e)) from None
    return Response(status_code=204)
