"""Counting failures per key (e.g. client address) in a sliding window.

In memory, per server process: it resets on restart and is not shared
between processes. Enough for one local server; a multi-process deployment
moves this to the database or Redis (plan, Day 25).
"""

import time
from collections import defaultdict, deque


class FailureLimiter:
    def __init__(self, max_failures: int, window_s: float) -> None:
        self.max_failures = max_failures
        self.window_s = window_s
        self._failures: dict[str, deque[float]] = defaultdict(deque)

    def _trim(self, key: str) -> deque[float]:
        q = self._failures[key]
        cutoff = time.monotonic() - self.window_s
        while q and q[0] < cutoff:
            q.popleft()
        return q

    def blocked(self, key: str) -> bool:
        return len(self._trim(key)) >= self.max_failures

    def failed(self, key: str) -> None:
        self._trim(key).append(time.monotonic())

    def reset(self) -> None:
        self._failures.clear()
