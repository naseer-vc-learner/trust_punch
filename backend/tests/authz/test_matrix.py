"""The permission matrix, cell by cell, and deny-by-default routing.

For every role x permission, a person holding just that role at its home
scope is checked against four objects: one inside their scope, one elsewhere
in the company, their own record elsewhere, and one in another company. The
expected answer comes from the cell's meaning (T / O / home scope / none),
so every one of the matrix's cells is proven, not just a sample.
"""

import pytest
from fastapi import APIRouter, FastAPI

from app.core.access import route_access, unmarked_routes, verify_routes
from app.main import create_app
from app.modules.roles.deps import require
from app.rbac import policy
from app.rbac.permissions import ASSIGNABLE_AT, HOME, MATRIX, RANK, ROLES
from app.rbac.policy import Actor, Grant, Resource

ME, T1, T2 = "u-me", "tenant-1", "tenant-2"

# Where each home letter is assigned for these tests.
HOME_GRANT = {
    "T": ("tenant", T1),
    "R": ("region", "r1"),
    "S": ("site", "s1"),
    "M": ("team", "m1"),
    "F": ("team", "m1"),
    "O": ("tenant", T1),
}

INSIDE = Resource(T1, region_id="r1", site_id="s1", team_id="m1", owner_user_id="u-other")
ELSEWHERE = Resource(T1, region_id="r2", site_id="s2", team_id="m2", owner_user_id="u-other")
OWN_ELSEWHERE = Resource(T1, region_id="r2", site_id="s2", team_id="m2", owner_user_id=ME)
OTHER_TENANT = Resource(T2, region_id="r1", site_id="s1", team_id="m1", owner_user_id=ME)
OBJECTS = {
    "inside": INSIDE,
    "elsewhere": ELSEWHERE,
    "own": OWN_ELSEWHERE,
    "other_tenant": OTHER_TENANT,
}


def _expected(letter: str | None) -> dict[str, bool]:
    if letter is None:
        return dict.fromkeys(OBJECTS, False)
    if letter == "T":
        return {"inside": True, "elsewhere": True, "own": True, "other_tenant": False}
    if letter == "O":
        return {"inside": False, "elsewhere": False, "own": True, "other_tenant": False}
    return {"inside": True, "elsewhere": False, "own": False, "other_tenant": False}


def _actor(role: str) -> Actor:
    scope_type, scope_id = HOME_GRANT[HOME[role]]
    return Actor(ME, T1, (Grant(role, scope_type, scope_id),))


CELLS = [(role, perm) for perm in sorted(MATRIX) for role in ROLES]


@pytest.mark.parametrize(("role", "permission"), CELLS)
def test_every_cell_means_what_it_says(role, permission):
    actor = _actor(role)
    letter = MATRIX[permission].get(role)
    got = {name: policy.allows(actor, permission, obj) for name, obj in OBJECTS.items()}
    assert got == _expected(letter), (role, permission, letter)
    assert policy.has_permission(actor, permission) is (letter is not None)


@pytest.mark.parametrize(("role", "permission"), CELLS)
def test_every_letter_is_t_o_or_the_roles_own_scope(role, permission):
    letter = MATRIX[permission].get(role)
    assert letter in (None, "T", "O", HOME[role]), (role, permission, letter)


def test_roles_are_consistent():
    assert set(RANK) == set(HOME) == set(ASSIGNABLE_AT) == set(ROLES)
    assert sorted(RANK.values(), reverse=True) == [RANK[r] for r in ROLES]
    # Only supervisors recommend; nobody else holds those two.
    assert set(MATRIX["corrections.recommend"]) == {"supervisor"}
    assert set(MATRIX["leave.recommend"]) == {"supervisor"}
    # Everyone may act on their own punches, leave and timesheets.
    for perm in ("punch.create", "leave.apply", "corrections.request", "activity.submit"):
        assert MATRIX[perm] == dict.fromkeys(ROLES, "O")


def test_a_region_wide_role_assigned_tenant_wide_reaches_everything():
    actor = Actor(ME, T1, (Grant("admin_l2", "tenant", T1),))
    assert policy.allows(actor, "users.read", ELSEWHERE)
    assert not policy.allows(actor, "users.read", OTHER_TENANT)


def test_reach_lists_what_a_person_covers():
    actor = Actor(ME, T1, (Grant("manager_l2", "site", "s1"), Grant("supervisor", "team", "m9")))
    r = policy.reach(actor, "attendance.read")
    assert (r.tenant, r.sites, r.teams, r.own) == (False, {"s1"}, {"m9"}, False)
    assert policy.reach(actor, "corrections.recommend").teams == {"m9"}
    assert not policy.reach(actor, "payroll.run").anything


def test_rank_over_counts_only_grants_reaching_the_target():
    actor = Actor(ME, T1, (Grant("admin_l3", "site", "s1"), Grant("manager_l2", "site", "s2")))
    assert policy.rank_over(actor, "roles.assign", Resource(T1, site_id="s1")) == 80
    assert policy.rank_over(actor, "roles.assign", Resource(T1, site_id="s2")) == 60
    assert policy.rank_over(actor, "roles.assign", Resource(T1, site_id="s3")) == 0


class TestDenyByDefault:
    def test_every_route_declares_who_may_call_it(self):
        app = create_app()
        found = route_access(app)
        # The walk must really see the routes (included routers too), or
        # "nothing unmarked" would mean nothing.
        assert len(found) >= 15
        assert unmarked_routes(app) == []

    def test_an_undeclared_route_stops_the_app_from_starting(self):
        app = FastAPI()

        @app.get("/oops")
        def oops() -> dict:
            return {}

        with pytest.raises(RuntimeError, match="/oops"):
            verify_routes(app)

    def test_an_undeclared_route_in_an_included_router_is_caught(self):
        router = APIRouter()

        @router.get("/hidden")
        def hidden() -> dict:
            return {}

        app = FastAPI()
        app.include_router(router, prefix="/v1")
        with pytest.raises(RuntimeError, match="/v1/hidden"):
            verify_routes(app)

    def test_an_app_with_no_visible_routes_refuses_to_start(self):
        with pytest.raises(RuntimeError, match="No API routes"):
            verify_routes(FastAPI())

    def test_a_misspelt_permission_fails_at_import(self):
        with pytest.raises(ValueError, match="unknown permission"):
            require("users.raed")

    def test_route_access_is_what_we_expect(self):
        kinds = {(r.methods[0], r.path): r.kinds for r in route_access(create_app())}
        assert "public" in kinds[("POST", "/v1/auth/login")]
        assert "device" in kinds[("POST", "/v1/punches/batch")]
        assert "self" in kinds[("GET", "/v1/me")]
        assert "perm:roles.assign" in kinds[("POST", "/v1/users/{user_id}/roles")]
        assert "perm:users.read" in kinds[("GET", "/v1/users/{user_id}/roles")]
