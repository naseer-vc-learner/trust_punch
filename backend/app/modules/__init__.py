"""Domain modules. Each has the same shape:

    router.py   HTTP: request/response models, status codes
    deps.py     FastAPI dependencies other modules may use (e.g. "who is calling")
    service.py  rules and transactions
    repo.py     SQL, nothing else

Another module may import only a module's service.py and deps.py.

tests/unit/test_architecture.py enforces these boundaries.
"""
