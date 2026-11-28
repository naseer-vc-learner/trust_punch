"""Roles and the permission matrix (docs/CONNECTED_PLATFORM_PLAN.md, section 5).

Each cell says how far a role's permission reaches:

    T  the whole tenant (company), whatever the role is assigned to
    O  only the person's own records
    R / S / M / F  within what the role is assigned to: its region, site or
       team ("F", the supervisor's crew, is the team until shift-level
       scoping arrives on Day 13). The letter must be the role's home scope;
       a test fails on any other letter, which catches typos.
    -  no access (left out of the dict)

Read-only cells marked "Rd" in the plan are that role's home scope here, as
the permission itself is a read. Cells marked "*" carry an extra rule that
the owning service enforces (e.g. a site manager may edit only supervisors
and staff). Billing delegated to Admin L2 ("T*") is off until delegation
exists.
"""

from types import MappingProxyType

# Highest first. A role may only be granted by someone holding a higher one.
RANK: dict[str, int] = {
    "admin_l1": 100,
    "admin_l2": 90,
    "admin_l3": 80,
    "manager_l1": 70,
    "manager_l2": 60,
    "manager_l3": 50,
    "supervisor": 40,
    "staff": 10,
}
ROLES = tuple(RANK)

# The letter of each role's own scope, and the scope types it can be assigned at.
HOME: dict[str, str] = {
    "admin_l1": "T",
    "admin_l2": "R",
    "admin_l3": "S",
    "manager_l1": "R",
    "manager_l2": "S",
    "manager_l3": "M",
    "supervisor": "F",
    "staff": "O",
}
ASSIGNABLE_AT: dict[str, frozenset[str]] = {
    "admin_l1": frozenset({"tenant"}),
    "admin_l2": frozenset({"tenant", "region"}),
    "admin_l3": frozenset({"site"}),
    "manager_l1": frozenset({"tenant", "region"}),
    "manager_l2": frozenset({"site"}),
    "manager_l3": frozenset({"team"}),
    "supervisor": frozenset({"team"}),
    "staff": frozenset({"tenant"}),
}
SCOPE_TYPES = ("tenant", "region", "site", "team")

_A1, _A2, _A3, _M1, _M2, _M3, _SUP, _ST = ROLES


def _row(
    a1: str = "",
    a2: str = "",
    a3: str = "",
    m1: str = "",
    m2: str = "",
    m3: str = "",
    sup: str = "",
    staff: str = "",
) -> dict[str, str]:
    """One matrix row, in the plan's column order (A-L1 ... Staff)."""
    cells = {_A1: a1, _A2: a2, _A3: a3, _M1: m1, _M2: m2, _M3: m3, _SUP: sup, _ST: staff}
    return {role: letter for role, letter in cells.items() if letter}


_EVERYONE_OWN = _row("O", "O", "O", "O", "O", "O", "O", "O")
_ADMINS_ONLY = _row("T", "R")
_WIDE_READ = _row("T", "R", "S", "R", "S", "M", "F", "O")

MATRIX: MappingProxyType[str, dict[str, str]] = MappingProxyType(
    {
        # Org / billing / global
        "tenant.read": _row("T", "T"),
        "tenant.update": _row("T"),
        "billing.read": _row("T"),
        "billing.update": _row("T"),
        "integrations.manage": _ADMINS_ONLY,
        # Users & roles
        "users.read": _WIDE_READ,
        "users.create": _row("T", "R", "S", "", "S"),
        "users.update": _row("T", "R", "S", "", "S", "", "", "O"),
        "users.deactivate": _row("T", "R", "S"),
        "users.erase": _ADMINS_ONLY,
        "roles.assign": _row("T", "R", "S", "R", "S"),
        # Sites / geofences / kiosks / devices
        "sites.read": _WIDE_READ,
        "sites.create": _ADMINS_ONLY,
        "sites.delete": _ADMINS_ONLY,
        "sites.update": _row("T", "R", "S", "", "S"),
        "geofences.manage": _row("T", "R", "S", "", "S"),
        "kiosks.read": _row("T", "R", "S", "R", "S", "M", "F"),
        "kiosks.manage": _row("T", "R", "S", "", "S"),
        "kiosks.override": _row("T", "R", "S", "", "S", "", "F"),
        "devices.block": _row("T", "R", "S", "", "S", "", "", "O"),
        # Policies
        "policies.read": _row("T", "R", "S", "R", "S"),
        "policies.edit": _ADMINS_ONLY,
        "policies.publish": _ADMINS_ONLY,
        # Shifts
        "shifts.read": _WIDE_READ,
        "shifts.manage": _row("T", "R", "S", "R", "S"),
        "shifts.assign": _row("T", "R", "S", "R", "S", "M", "F"),
        "shifts.respond": _EVERYONE_OWN,
        # Attendance
        "punch.create": _EVERYONE_OWN,
        "attendance.read": _WIDE_READ,
        "attendance.live": _row("T", "R", "S", "R", "S", "M", "F"),
        "attendance.verify": _row("T", "R", "S", "", "S", "M", "F"),
        # Corrections & overtime
        "corrections.request": _EVERYONE_OWN,
        "corrections.request_for": _row("T", "R", "S", "", "S", "M", "F"),
        "corrections.recommend": _row(sup="F"),
        "corrections.approve": _row("T", "R", "S", "R", "S", "M"),
        "overtime.approve": _row("T", "R", "S", "R", "S", "M"),
        # Leave
        "leave.apply": _EVERYONE_OWN,
        "leave.cancel": _EVERYONE_OWN,
        "leave.apply_for": _row("T", "R", "S", "", "S", "M"),
        "leave.recommend": _row(sup="F"),
        "leave.approve": _row("T", "R", "S", "R", "S", "M"),
        "leave.configure": _ADMINS_ONLY,
        # Jobs / activities
        "jobs.read": _WIDE_READ,
        "jobs.manage": _row("T", "R", "S", "R", "S"),
        "jobs.assign": _row("T", "R", "S", "R", "S", "M", "F"),
        "activity.submit": _EVERYONE_OWN,
        "activity.approve": _row("T", "R", "S", "R", "S", "M", "F"),
        # Reports & exports
        "reports.read": _WIDE_READ,
        "reports.export": _row("T", "R", "S", "R", "S", "M", "", "O"),
        # Payroll
        "payroll.read": _row("T", "R", "S", "R", "S"),
        "payroll.run": _ADMINS_ONLY,
        "payroll.lock": _ADMINS_ONLY,
        "payroll.export": _ADMINS_ONLY,
        # Audit / alerts / privacy
        "audit.read": _row("T", "R", "S", "R", "S"),
        "alerts.read": _WIDE_READ,
        "alerts.review": _row("T", "R", "S", "R", "S", "M"),
        "face.enroll": _row("T", "R", "S", "", "S", "", "F", "O"),
        "face.delete": _row("T", "R", "S", "", "S"),
        "privacy.export": _ADMINS_ONLY,
        "privacy.erase": _ADMINS_ONLY,
    }
)

PERMISSIONS = frozenset(MATRIX)


def letter(role: str, permission: str) -> str | None:
    return MATRIX[permission].get(role)
