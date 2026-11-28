"""Deny by default: every route must say who may call it, or the app won't start.

A route declares its access through a dependency carrying a marker:

    public                    anyone (health, login, refresh, pairing)
    device                    a paired, unblocked device (devices.deps.current_device)
    self                      any signed-in user, acting on their own records
                              (auth.deps.current_user)
    perm:<permission>         a permission from the matrix (roles.deps.require)

`verify_routes(app)` walks every route's dependencies at start-up and refuses
to start if one has no marker, so a new endpoint can't ship open by mistake.

Included routers: recent FastAPI keeps `include_router()` as a wrapper
holding `original_router` instead of copying routes onto the app. The walk
follows those wrappers (and reads their prefix and router-level
dependencies when present). If the walk finds no routes at all, that is
treated as a failure too, so a future FastAPI change can't make this check
pass silently by hiding the routes from it.
"""

from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from typing import Any

from fastapi import FastAPI
from fastapi.dependencies.models import Dependant
from fastapi.routing import APIRoute

ACCESS_ATTR = "__trustpunch_access__"


def mark(fn: Callable[..., Any], kind: str) -> Callable[..., Any]:
    setattr(fn, ACCESS_ATTR, kind)
    return fn


def public() -> None:
    """Marks a route as open to anyone. Use: dependencies=[Depends(public)]."""


mark(public, "public")


@dataclass(frozen=True)
class RouteAccess:
    methods: tuple[str, ...]
    path: str  # with the prefix it is served under
    kinds: tuple[str, ...]  # e.g. ("public",), ("perm:users.read",)


def _calls(dependant: Dependant) -> Iterator[Callable[..., Any]]:
    for dep in dependant.dependencies:
        if dep.call is not None:
            yield dep.call
        yield from _calls(dep)


def _kinds(calls: Iterable[Callable[..., Any]]) -> tuple[str, ...]:
    return tuple(kind for call in calls if (kind := getattr(call, ACCESS_ATTR, None)))


def access_of(route: APIRoute) -> list[str]:
    return list(_kinds(_calls(route.dependant)))


def _walk(
    routes: Iterable[Any], prefix: str, inherited: tuple[Callable[..., Any], ...]
) -> Iterator[RouteAccess]:
    for route in routes:
        if isinstance(route, APIRoute):
            yield RouteAccess(
                methods=tuple(sorted(route.methods or ())),
                path=prefix + route.path,
                kinds=_kinds(inherited) + _kinds(_calls(route.dependant)),
            )
            continue
        inner = getattr(route, "original_router", None)
        if inner is None:
            continue  # framework routes (e.g. the debug-only /docs page)
        context = getattr(route, "include_context", None)
        extra = tuple(
            d.dependency for d in (getattr(context, "dependencies", None) or ()) if d.dependency
        )
        yield from _walk(
            inner.routes, prefix + (getattr(context, "prefix", "") or ""), inherited + extra
        )


def route_access(app: FastAPI) -> list[RouteAccess]:
    return list(_walk(app.routes, "", ()))


def unmarked_routes(app: FastAPI) -> list[str]:
    return [f"{','.join(r.methods)} {r.path}" for r in route_access(app) if not r.kinds]


def verify_routes(app: FastAPI) -> None:
    found = route_access(app)
    if not found:
        raise RuntimeError(
            "No API routes were found to check access on; FastAPI may have changed how "
            "routers are stored (see app/core/access.py)."
        )
    missing = [f"{','.join(r.methods)} {r.path}" for r in found if not r.kinds]
    if missing:
        raise RuntimeError(
            "These routes do not declare who may call them (see app/core/access.py): "
            + "; ".join(missing)
        )
