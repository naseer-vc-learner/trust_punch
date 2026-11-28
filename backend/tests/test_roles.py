"""Roles over HTTP: what /v1/me reports, granting and removing roles, and the
no-escalation rules (only ranks below your own, never yourself)."""

import sqlite3
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from app.core.config import DEFAULT_TENANT_ID as T1
from app.core.db import engine
from app.main import app
from app.modules.roles import service as roles
from app.modules.users import service as users
from app.rbac.permissions import MATRIX

client = TestClient(app)
PASSWORD = "correct horse battery"


def _user(name: str, *grants: tuple[str, str, str | None], tenant: str = T1) -> str:
    with engine().connect() as conn:
        user_id = users.create_user(conn, tenant, name, name.title(), PASSWORD)
        conn.commit()
        for role, scope_type, scope_id in grants:
            roles.grant(conn, None, tenant, user_id, role, scope_type, scope_id)
    return user_id


def _token(name: str) -> dict[str, str]:
    r = client.post("/v1/auth/login", json={"username": name, "password": PASSWORD})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['accessToken']}"}


def _grant(as_user: str, user_id: str, role: str, scope_type: str, scope_id: str | None = None):
    body = {"role": role, "scopeType": scope_type}
    if scope_id:
        body["scopeId"] = scope_id
    return client.post(f"/v1/users/{user_id}/roles", headers=_token(as_user), json=body)


@pytest.fixture
def org():
    """admin (Admin L1), bob (Admin L3 at site s1), carol and dave (no roles yet)."""
    return {
        "admin": _user("admin", ("admin_l1", "tenant", None)),
        "bob": _user("bob", ("admin_l3", "site", "s1")),
        "carol": _user("carol"),
        "dave": _user("dave", ("staff", "tenant", None)),
    }


class TestMe:
    def test_admin_sees_roles_and_permissions(self, org):
        me = client.get("/v1/me", headers=_token("admin")).json()
        assert me["roles"] == [{"role": "admin_l1", "scopeType": "tenant", "scopeId": T1}]
        expected = sorted(p for p, cells in MATRIX.items() if "admin_l1" in cells)
        assert me["permissions"] == expected
        assert "roles.assign" in me["permissions"]
        assert "leave.recommend" not in me["permissions"]  # supervisors only

    def test_staff_sees_only_own_record_permissions(self, org):
        me = client.get("/v1/me", headers=_token("dave")).json()
        expected = sorted(p for p, cells in MATRIX.items() if cells.get("staff") == "O")
        assert me["permissions"] == expected
        assert "roles.assign" not in me["permissions"]

    def test_no_roles_means_no_permissions(self, org):
        assert client.get("/v1/me", headers=_token("carol")).json()["permissions"] == []

    def test_role_catalogue_needs_sign_in(self):
        assert client.get("/v1/roles").status_code == 401
        _user("eve")
        catalogue = client.get("/v1/roles", headers=_token("eve")).json()
        assert [r["role"] for r in catalogue][0] == "admin_l1"
        assert len(catalogue) == 8


class TestGranting:
    def test_admin_grants_a_site_role(self, org):
        r = _grant("admin", org["carol"], "manager_l2", "site", "s1")
        assert r.status_code == 201, r.text
        body = r.json()
        assert (body["role"], body["scopeType"], body["scopeId"]) == ("manager_l2", "site", "s1")
        assert body["grantedBy"] == org["admin"]
        listed = client.get(f"/v1/users/{org['carol']}/roles", headers=_token("admin")).json()
        assert [a["id"] for a in listed] == [body["id"]]

    def test_granting_twice_is_harmless(self, org):
        first = _grant("admin", org["carol"], "staff", "tenant").json()["id"]
        second = _grant("admin", org["carol"], "staff", "tenant").json()["id"]
        assert first == second

    def test_site_admin_grants_below_own_rank_inside_own_site(self, org):
        assert _grant("bob", org["carol"], "manager_l2", "site", "s1").status_code == 201

    def test_no_equal_or_higher_rank(self, org):
        r = _grant("bob", org["carol"], "admin_l3", "site", "s1")
        assert r.status_code == 403
        assert "below your own" in r.json()["detail"]
        assert _grant("bob", org["carol"], "admin_l1", "tenant").status_code == 403

    def test_not_outside_own_scope(self, org):
        r = _grant("bob", org["carol"], "manager_l2", "site", "s2")
        assert r.status_code == 403
        assert "outside" in r.json()["detail"]

    def test_never_to_yourself(self, org):
        r = _grant("admin", org["admin"], "staff", "tenant")
        assert r.status_code == 403
        assert "your own roles" in r.json()["detail"]

    def test_without_roles_assign_it_is_403(self, org):
        assert _grant("dave", org["carol"], "staff", "tenant").status_code == 403
        assert _grant("carol", org["dave"], "staff", "tenant").status_code == 403

    @pytest.mark.parametrize(
        ("role", "scope_type", "scope_id"),
        [
            ("supervisor", "tenant", None),  # supervisors belong to a team
            ("admin_l1", "site", "s1"),  # admin L1 is tenant-wide only
            ("manager_l2", "site", None),  # a site role needs the site
            ("chief", "tenant", None),  # no such role
        ],
    )
    def test_invalid_grants_are_422(self, org, role, scope_type, scope_id):
        assert _grant("admin", org["carol"], role, scope_type, scope_id).status_code == 422

    def test_unknown_user_is_404(self, org):
        assert _grant("admin", "no-such-user", "staff", "tenant").status_code == 404


class TestRemoving:
    def test_admin_removes_a_role(self, org):
        assignment = _grant("admin", org["carol"], "manager_l2", "site", "s1").json()["id"]
        r = client.delete(f"/v1/users/{org['carol']}/roles/{assignment}", headers=_token("admin"))
        assert r.status_code == 204
        assert client.get(f"/v1/users/{org['carol']}/roles", headers=_token("admin")).json() == []

    def test_a_site_admin_cannot_remove_a_higher_role(self, org):
        admin_role = roles.assignments(engine().connect(), org["admin"])[0]["id"]
        r = client.delete(f"/v1/users/{org['admin']}/roles/{admin_role}", headers=_token("bob"))
        assert r.status_code == 403

    def test_nobody_removes_their_own_role(self, org):
        own = client.get(f"/v1/users/{org['admin']}/roles", headers=_token("admin")).json()[0]
        r = client.delete(f"/v1/users/{org['admin']}/roles/{own['id']}", headers=_token("admin"))
        assert r.status_code == 403

    def test_the_last_admin_l1_stays(self, org):
        with engine().connect() as conn:
            only = roles.assignments(conn, org["admin"])[0]["id"]
            with pytest.raises(roles.LastAdmin):
                roles.revoke(conn, None, T1, org["admin"], only)

    def test_an_assignment_of_someone_else_is_404(self, org):
        bobs = roles.assignments(engine().connect(), org["bob"])[0]["id"]
        r = client.delete(f"/v1/users/{org['carol']}/roles/{bobs}", headers=_token("admin"))
        assert r.status_code == 404


class TestReadingRoles:
    def test_staff_see_their_own_roles_only(self, org):
        assert (
            client.get(f"/v1/users/{org['dave']}/roles", headers=_token("dave")).status_code == 200
        )
        # Someone else's: 404, exactly like a user that doesn't exist.
        other = client.get(f"/v1/users/{org['admin']}/roles", headers=_token("dave"))
        missing = client.get("/v1/users/nobody/roles", headers=_token("dave"))
        assert other.status_code == missing.status_code == 404
        assert other.json()["detail"] == missing.json()["detail"]

    def test_no_roles_at_all_is_403(self, org):
        r = client.get(f"/v1/users/{org['carol']}/roles", headers=_token("carol"))
        assert r.status_code == 403

    def test_another_tenants_user_is_404(self, org, fresh_db):
        db = sqlite3.connect(fresh_db)
        db.execute(
            "INSERT INTO tenants (id, name, timezone, created_at) VALUES (?, ?, ?, ?)",
            ("tenant-2", "Other Co", "Asia/Dubai", datetime.now(UTC).isoformat()),
        )
        db.commit()
        db.close()
        stranger = _user("stranger", tenant="tenant-2")
        assert client.get(f"/v1/users/{stranger}/roles", headers=_token("admin")).status_code == 404
        assert _grant("admin", stranger, "staff", "tenant").status_code == 404


class TestCommands:
    def test_create_admin_grants_admin_l1(self, monkeypatch, capsys):
        from app import cli

        answers = iter([PASSWORD, PASSWORD])
        monkeypatch.setattr(cli.getpass, "getpass", lambda _p: next(answers))
        assert cli.main(["create-admin", "--username", "owner"]) == 0
        assert "as admin_l1" in capsys.readouterr().out
        me = client.get("/v1/me", headers=_token("owner")).json()
        assert me["roles"][0]["role"] == "admin_l1"

    def test_grant_role_and_list_roles(self, capsys):
        from app import cli

        _user("frank")
        assert (
            cli.main(
                ["grant-role", "frank", "supervisor", "--scope-type", "team", "--scope-id", "m1"]
            )
            == 0
        )
        assert cli.main(["roles", "frank"]) == 0
        out = capsys.readouterr().out
        assert "supervisor" in out and "m1" in out
        assert cli.main(["grant-role", "frank", "supervisor"]) == 1  # needs a team
