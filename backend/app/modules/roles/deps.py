"""`require(permission)`: the dependency every protected route uses.

    @router.get("/things/{id}")
    def read(id: str, access: Annotated[Access, require("things.read")], conn: Conn):
        thing = load(conn, id)                       # 404 if it doesn't exist
        access.check(Resource(thing.tenant_id, site_id=thing.site_id, ...))
        ...

- No grant that reaches anything with this permission: 403.
- A grant exists, but not for this object (another site, another tenant,
  someone else's record): 404, the same as a missing object, so ids can't
  be probed (OWASP API1).
"""

from typing import Any

from fastapi import Depends, HTTPException

from app.core.access import mark
from app.core.db import Conn
from app.modules.auth.deps import CurrentUser
from app.modules.auth.service import Principal
from app.rbac import policy
from app.rbac.permissions import PERMISSIONS
from app.rbac.policy import Actor, Reach, Resource

from . import service

NOT_FOUND = "Not found"


class Access:
    """What one request may do with one permission."""

    def __init__(self, principal: Principal, actor: Actor, permission: str) -> None:
        self.principal = principal
        self.actor = actor
        self.permission = permission

    def allows(self, obj: Resource) -> bool:
        return policy.allows(self.actor, self.permission, obj)

    def check(self, obj: Resource) -> None:
        if not self.allows(obj):
            raise HTTPException(404, NOT_FOUND)

    @property
    def reach(self) -> Reach:
        return policy.reach(self.actor, self.permission)


def require(permission: str) -> Any:
    """A dependency enforcing [permission]; fails at import on a typo."""
    if permission not in PERMISSIONS:
        raise ValueError(f"unknown permission {permission!r}")

    def dependency(user: CurrentUser, conn: Conn) -> Access:
        actor = service.actor_for(conn, user.user_id, user.tenant_id)
        if not policy.has_permission(actor, permission):
            raise HTTPException(403, "You don't have permission for this")
        return Access(user, actor, permission)

    dependency.__name__ = "require_" + permission.replace(".", "_")
    mark(dependency, f"perm:{permission}")
    return Depends(dependency)
