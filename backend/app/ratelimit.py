"""Rolling-window rate limiter (in-memory, thread-safe)."""

import threading
import time
from collections import deque


class RateLimiter:
    """Allow at most `max_calls` per `window_s` (rolling window)."""

    def __init__(self, max_calls: int, window_s: float = 60.0):
        self.max_calls = max_calls
        self.window_s = window_s
        self._calls: deque[float] = deque()
        self._lock = threading.Lock()

    def allow(self, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        with self._lock:
            while self._calls and self._calls[0] <= now - self.window_s:
                self._calls.popleft()
            if len(self._calls) >= self.max_calls:
                return False
            self._calls.append(now)
            return True
