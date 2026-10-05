"""In-process TTL cache for AI location guesses, so repeated queries don't re-call the model."""
from __future__ import annotations

import threading
import time
from collections import OrderedDict

from .catalog import LayoutDef
from .intent import Intent
from .reasoning import LocationGuess


class CachedLocationModel:
    def __init__(self, model, ttl_seconds: float = 6 * 3600, max_entries: int = 2048, clock=time.monotonic):
        self.name = model.name
        self._model = model
        self._ttl = ttl_seconds
        self._max = max_entries
        self._clock = clock
        self._entries: OrderedDict[tuple, tuple[float, LocationGuess | None]] = OrderedDict()
        self._lock = threading.Lock()

    def locate(self, intent: Intent, retailer_name: str | None, layout: LayoutDef) -> LocationGuess | None:
        if not intent.phrase:
            return None  # Nothing to ask about (only emoji or punctuation).
        # Exactly what the model is asked about, so one query's guess is never another's.
        key = (layout.key, (retailer_name or "").lower(), intent.phrase)
        now = self._clock()
        with self._lock:
            hit = self._entries.get(key)
            if hit and now - hit[0] < self._ttl:
                self._entries.move_to_end(key)
                return hit[1]
        guess = self._model.locate(intent, retailer_name, layout)
        if guess is not None:  # Don't cache failures; the provider may recover.
            with self._lock:
                self._entries[key] = (now, guess)
                self._entries.move_to_end(key)
                while len(self._entries) > self._max:
                    self._entries.popitem(last=False)
        return guess
