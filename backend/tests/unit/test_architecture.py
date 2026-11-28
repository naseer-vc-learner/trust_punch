"""The layer rules, checked on every import in app/ (see app/modules/__init__.py).

1. app.core and app.rbac import nothing from app.modules or app.main
   (app.rbac is pure rules; it may use app.core).
2. A module reaches another module only through its service.py or deps.py.
3. Inside a module: repo.py imports no router/service/deps; service.py no router.
4. Nothing imports app.main or app.cli (they are entry points).
"""

import ast
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "app"


def _module_name(path: Path) -> str:
    rel = path.relative_to(APP.parent).with_suffix("")
    return ".".join(rel.parts).removesuffix(".__init__")


def _imports(path: Path) -> list[str]:
    tree = ast.parse(path.read_text(), filename=str(path))
    package = _module_name(path)
    if path.name != "__init__.py":
        package = package.rsplit(".", 1)[0]
    names: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names += [a.name for a in node.names]
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                base = package.split(".")
                base = base[: len(base) - (node.level - 1)]
                prefix = ".".join(base)
                target = f"{prefix}.{node.module}" if node.module else prefix
            else:
                target = node.module or ""
            names.append(target)
            names += [f"{target}.{a.name}" for a in node.names]
    return [n for n in names if n == "app" or n.startswith("app.")]


def _violations() -> list[str]:
    found: list[str] = []
    for path in sorted(APP.rglob("*.py")):
        me = _module_name(path)
        parts = me.split(".")
        for target in _imports(path):
            t = target.split(".")
            if t[:2] in (["app", "main"], ["app", "cli"]) and me not in ("app.main", "app.cli"):
                found.append(f"{me} imports entry point {target}")
            if parts[:2] == ["app", "core"] and t[:2] in (["app", "modules"], ["app", "main"]):
                found.append(f"{me}: core must not import {target}")
            if parts[:2] == ["app", "rbac"] and t[:2] in (["app", "modules"], ["app", "main"]):
                found.append(f"{me}: rbac must not import {target}")
            if parts[:2] == ["app", "modules"] and len(parts) >= 4 and t[:2] == ["app", "modules"]:
                if len(t) < 3:
                    continue
                mine, theirs = parts[2], t[2]
                layer = parts[3]
                if theirs != mine:
                    if len(t) >= 4 and t[3] not in ("service", "deps"):
                        found.append(f"{me} reaches into {target} (only service/deps allowed)")
                else:
                    inner = t[3] if len(t) >= 4 else None
                    if layer == "repo" and inner in ("router", "service", "deps"):
                        found.append(f"{me}: repo must not import {target}")
                    if layer == "service" and inner == "router":
                        found.append(f"{me}: service must not import {target}")
    return found


def test_layer_rules_hold():
    assert _violations() == []


def test_the_checker_catches_a_violation(tmp_path, monkeypatch):
    bad = APP / "core" / "_arch_probe.py"
    bad.write_text("from app.modules.devices.repo import by_token_hash\n")
    try:
        assert any("core must not import" in v for v in _violations())
    finally:
        bad.unlink()
