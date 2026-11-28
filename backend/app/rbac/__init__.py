"""Who may do what, where: roles, the permission matrix, and the decision.

Pure data and pure functions: nothing here reads the database or knows about
HTTP. Storage of role assignments lives in app.modules.roles; the FastAPI
dependency that enforces a permission is app.modules.roles.deps.require().
Imports nothing from app.modules (tests/unit/test_architecture.py).
"""
