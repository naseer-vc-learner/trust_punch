"""The access decision: may this person use this permission on this object?

An object is described by where it sits (tenant → region → site → team) and
whose it is. The module that owns the object fills that in; until the org
structure exists (Day 6) region/site/team are whatever ids the caller knows.

Rules:
- Another tenant's object is never reachable.
- "T" reaches the whole tenant, "O" only the person's own objects.
- Otherwise the grant reaches what the role is assigned to: a region grant
  reaches everything whose region matches, a site grant everything at that
  site, a team grant everything in that team.
"""

from dataclasses import dataclass, field

from .permissions import MATRIX, RANK


@dataclass(frozen=True)
class Grant:
    role: str
    scope_type: str  # tenant | region | site | team
    scope_id: str


@dataclass(frozen=True)
class Actor:
    user_id: str
    tenant_id: str
    grants: tuple[Grant, ...] = ()


@dataclass(frozen=True)
class Resource:
    tenant_id: str
    region_id: str | None = None
    site_id: str | None = None
    team_id: str | None = None
    owner_user_id: str | None = None


@dataclass(frozen=True)
class Reach:
    """Everything one permission reaches for one actor (for filtering lists)."""

    tenant: bool = False
    regions: frozenset[str] = field(default_factory=frozenset)
    sites: frozenset[str] = field(default_factory=frozenset)
    teams: frozenset[str] = field(default_factory=frozenset)
    own: bool = False

    @property
    def anything(self) -> bool:
        return self.tenant or self.own or bool(self.regions or self.sites or self.teams)


def _grant_reaches(actor: Actor, grant: Grant, permission: str, obj: Resource) -> bool:
    letter = MATRIX[permission].get(grant.role)
    if letter is None:
        return False
    if letter == "T":
        return True
    if letter == "O":
        return obj.owner_user_id is not None and obj.owner_user_id == actor.user_id
    if grant.scope_type == "tenant":
        return True
    if grant.scope_type == "region":
        return obj.region_id == grant.scope_id
    if grant.scope_type == "site":
        return obj.site_id == grant.scope_id
    if grant.scope_type == "team":
        return obj.team_id == grant.scope_id
    return False


def allows(actor: Actor, permission: str, obj: Resource) -> bool:
    if permission not in MATRIX:
        raise KeyError(f"unknown permission {permission!r}")
    if obj.tenant_id != actor.tenant_id:
        return False
    return any(_grant_reaches(actor, g, permission, obj) for g in actor.grants)


def has_permission(actor: Actor, permission: str) -> bool:
    """True if the permission reaches anything at all."""
    return reach(actor, permission).anything


def reach(actor: Actor, permission: str) -> Reach:
    if permission not in MATRIX:
        raise KeyError(f"unknown permission {permission!r}")
    tenant = own = False
    regions: set[str] = set()
    sites: set[str] = set()
    teams: set[str] = set()
    for g in actor.grants:
        letter = MATRIX[permission].get(g.role)
        if letter is None:
            continue
        if letter == "T" or (letter != "O" and g.scope_type == "tenant"):
            tenant = True
        elif letter == "O":
            own = True
        elif g.scope_type == "region":
            regions.add(g.scope_id)
        elif g.scope_type == "site":
            sites.add(g.scope_id)
        elif g.scope_type == "team":
            teams.add(g.scope_id)
    return Reach(tenant, frozenset(regions), frozenset(sites), frozenset(teams), own)


def permissions_of(actor: Actor) -> list[str]:
    """Every permission that reaches anything, sorted (for the app's UI)."""
    return sorted(p for p in MATRIX if has_permission(actor, p))


def rank_over(actor: Actor, permission: str, target: Resource) -> int:
    """The highest rank among the actor's grants that can use [permission] on
    [target]; 0 when none can. Used for "only ranks below your own"."""
    return max(
        (RANK[g.role] for g in actor.grants if _grant_reaches(actor, g, permission, target)),
        default=0,
    )
