"""Granting and removing roles, and building the Actor the access rules need.

Rules (plan, section 5.4):
- Grant only roles ranked below your own highest role that reaches the
  target scope with "roles.assign" (no privilege escalation).
- Never grant or remove your own roles.
- Each role can only be assigned at its scope types (a supervisor to a team,
  a site admin to a site, ...).
- The last Admin L1 of a tenant can't be removed (nobody could fix it).
- Granting the same role at the same scope twice is harmless (idempotent).

`actor=None` means the operator on the server itself (app.cli): no rank
rules apply. Region, site and team ids are not checked against real org
records until those exist (Day 6), and a region grant does not yet reach
the sites inside it; until then only tenant-wide or exact-scope grants count.
"""

from datetime import UTC, datetime

from sqlalchemy import Connection, RowMapping

from app.core.ids import new_id
from app.modules.users import service as users
from app.rbac import policy
from app.rbac.permissions import ASSIGNABLE_AT, RANK
from app.rbac.policy import Actor, Grant, Resource

from . import repo

ASSIGN = "roles.assign"


class RoleError(Exception):
    pass


class NotAllowed(RoleError):
    pass


class InvalidGrant(RoleError):
    pass


class NotFound(RoleError):
    pass


class LastAdmin(RoleError):
    pass


def actor_for(conn: Connection, user_id: str, tenant_id: str) -> Actor:
    grants = tuple(
        Grant(r["role"], r["scope_type"], r["scope_id"])
        for r in repo.for_user(conn, user_id)
        if r["tenant_id"] == tenant_id
    )
    return Actor(user_id=user_id, tenant_id=tenant_id, grants=grants)


def assignments(conn: Connection, user_id: str) -> list[RowMapping]:
    return repo.for_user(conn, user_id)


def scope_resource(tenant_id: str, scope_type: str, scope_id: str) -> Resource:
    """The scope a role is granted at, as an object the rules can reach."""
    if scope_type == "region":
        return Resource(tenant_id, region_id=scope_id)
    if scope_type == "site":
        return Resource(tenant_id, site_id=scope_id)
    if scope_type == "team":
        return Resource(tenant_id, team_id=scope_id)
    return Resource(tenant_id)


def _check_rank(actor: Actor, target_user_id: str, role: str, scope: Resource) -> None:
    if target_user_id == actor.user_id:
        raise NotAllowed("you can't change your own roles")
    over = policy.rank_over(actor, ASSIGN, scope)
    if over == 0:
        raise NotAllowed("that scope is outside what you manage")
    if RANK[role] >= over:
        raise NotAllowed("you can only grant or remove roles ranked below your own")


def grant(
    conn: Connection,
    actor: Actor | None,
    tenant_id: str,
    target_user_id: str,
    role: str,
    scope_type: str,
    scope_id: str | None,
) -> str:
    """Grants [role] at the scope; returns the assignment id (existing or new)."""
    if role not in RANK:
        raise InvalidGrant(f"unknown role {role!r}")
    if scope_type not in ASSIGNABLE_AT[role]:
        allowed = ", ".join(sorted(ASSIGNABLE_AT[role]))
        raise InvalidGrant(f"{role} can be assigned at: {allowed}")
    if scope_type == "tenant":
        scope_id = tenant_id
    elif not scope_id:
        raise InvalidGrant(f"a {scope_type} id is needed")
    target = users.get(conn, target_user_id)
    if target is None or target["tenant_id"] != tenant_id:
        raise NotFound("no such user")
    if actor is not None:
        _check_rank(actor, target_user_id, role, scope_resource(tenant_id, scope_type, scope_id))

    for row in repo.for_user(conn, target_user_id):
        if (row["role"], row["scope_type"], row["scope_id"]) == (role, scope_type, scope_id):
            return str(row["id"])
    assignment_id = new_id()
    repo.insert(
        conn,
        {
            "id": assignment_id,
            "tenant_id": tenant_id,
            "user_id": target_user_id,
            "role": role,
            "scope_type": scope_type,
            "scope_id": scope_id,
            "granted_by": actor.user_id if actor else None,
            "created_at": datetime.now(UTC).isoformat(),
        },
    )
    conn.commit()
    return assignment_id


def revoke(
    conn: Connection, actor: Actor | None, tenant_id: str, user_id: str, assignment_id: str
) -> None:
    row = repo.by_id(conn, assignment_id)
    if row is None or row["tenant_id"] != tenant_id or row["user_id"] != user_id:
        raise NotFound("no such role assignment")
    if actor is not None:
        scope = scope_resource(tenant_id, row["scope_type"], row["scope_id"])
        _check_rank(actor, user_id, row["role"], scope)
    if row["role"] == "admin_l1" and repo.count_role(conn, tenant_id, "admin_l1") <= 1:
        raise LastAdmin("the last Admin L1 can't be removed; grant the role to someone else first")
    repo.delete(conn, assignment_id)
    conn.commit()
