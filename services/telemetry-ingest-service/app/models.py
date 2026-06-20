"""
NeuroSphere Telemetry Ingest Service — Data Models

Defines the TelemetryEvent dataclass and a thread-safe CircularBuffer
optimized for high-throughput ingestion of robot/device telemetry.
"""

import threading
import time
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
VALID_SOURCE_TYPES = frozenset([
    "robot",
    "diagnostic_device",
    "patient_monitor",
    "gateway",
])

VALID_EVENT_TYPES = frozenset([
    "heartbeat",
    "status_update",
    "error",
    "metric",
    "alert",
    "command_ack",
])

BUFFER_MAX_SIZE = 10_000


# ---------------------------------------------------------------------------
# Telemetry Event
# ---------------------------------------------------------------------------
@dataclass(slots=True)
class TelemetryEvent:
    """A single telemetry event from a NeuroSphere source."""

    source_id: str
    source_type: str
    event_type: str
    timestamp: str
    payload: Dict[str, Any]
    ingested_at: float = field(default_factory=time.time)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


# ---------------------------------------------------------------------------
# Thread-safe Circular Buffer
# ---------------------------------------------------------------------------
class CircularBuffer:
    """
    Fixed-capacity circular buffer backed by a pre-allocated list.

    Designed for high-throughput, concurrent writes from the ingestion
    endpoint while supporting concurrent reads for the stats/recent APIs.

    * O(1) append — overwrites oldest entry when full.
    * Thread-safe via a single ``threading.Lock``.
    * Maintains rolling counters for events_by_type and events_by_source
      so that ``/api/telemetry/stats`` can respond without scanning.
    """

    def __init__(self, capacity: int = BUFFER_MAX_SIZE) -> None:
        self._capacity = capacity
        self._buffer: List[Optional[TelemetryEvent]] = [None] * capacity
        self._head = 0          # next write position
        self._size = 0          # current number of stored events
        self._total_events = 0  # lifetime counter
        self._lock = threading.Lock()

        # Rolling counters -------------------------------------------------
        self.events_by_type: Dict[str, int] = defaultdict(int)
        self.events_by_source_type: Dict[str, int] = defaultdict(int)
        self.events_by_source_id: Dict[str, int] = defaultdict(int)
        self.error_count: int = 0

        # Source liveness tracking ------------------------------------------
        # source_id -> last-seen epoch
        self.source_last_seen: Dict[str, float] = {}

    # -- writes -------------------------------------------------------------

    def append(self, event: TelemetryEvent) -> None:
        """Append a single event (O(1), thread-safe)."""
        with self._lock:
            self._buffer[self._head] = event
            self._head = (self._head + 1) % self._capacity
            if self._size < self._capacity:
                self._size += 1
            self._total_events += 1

            # counters
            self.events_by_type[event.event_type] += 1
            self.events_by_source_type[event.source_type] += 1
            self.events_by_source_id[event.source_id] += 1
            if event.event_type == "error":
                self.error_count += 1

            # liveness
            self.source_last_seen[event.source_id] = event.ingested_at

    def append_many(self, events: List[TelemetryEvent]) -> None:
        """Batch-append for reduced lock contention."""
        with self._lock:
            for event in events:
                self._buffer[self._head] = event
                self._head = (self._head + 1) % self._capacity
                if self._size < self._capacity:
                    self._size += 1
                self._total_events += 1

                self.events_by_type[event.event_type] += 1
                self.events_by_source_type[event.source_type] += 1
                self.events_by_source_id[event.source_id] += 1
                if event.event_type == "error":
                    self.error_count += 1
                self.source_last_seen[event.source_id] = event.ingested_at

    # -- reads --------------------------------------------------------------

    def recent(
        self,
        n: int = 100,
        source_type: Optional[str] = None,
        event_type: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        """Return the *n* most-recent events (newest first), optionally filtered."""
        with self._lock:
            result: List[Dict[str, Any]] = []
            idx = (self._head - 1) % self._capacity
            checked = 0
            while checked < self._size and len(result) < n:
                ev = self._buffer[idx]
                if ev is not None:
                    if source_type and ev.source_type != source_type:
                        idx = (idx - 1) % self._capacity
                        checked += 1
                        continue
                    if event_type and ev.event_type != event_type:
                        idx = (idx - 1) % self._capacity
                        checked += 1
                        continue
                    result.append(ev.to_dict())
                idx = (idx - 1) % self._capacity
                checked += 1
            return result

    def recent_errors(self, n: int = 100) -> List[Dict[str, Any]]:
        """Convenience: recent events with event_type == 'error'."""
        return self.recent(n=n, event_type="error")

    @property
    def size(self) -> int:
        with self._lock:
            return self._size

    @property
    def total_events(self) -> int:
        with self._lock:
            return self._total_events

    def active_sources(self, window_seconds: float = 60.0) -> List[str]:
        """Source IDs that reported within *window_seconds*."""
        cutoff = time.time() - window_seconds
        with self._lock:
            return [sid for sid, ts in self.source_last_seen.items() if ts >= cutoff]

    def silent_sources(self, window_seconds: float = 60.0) -> List[str]:
        """Source IDs that have NOT reported within *window_seconds*."""
        cutoff = time.time() - window_seconds
        with self._lock:
            return [sid for sid, ts in self.source_last_seen.items() if ts < cutoff]

    def error_rates_by_source(self) -> Dict[str, float]:
        """Error rate (errors / total) for each source_id, based on buffer scan."""
        with self._lock:
            source_total: Dict[str, int] = defaultdict(int)
            source_errors: Dict[str, int] = defaultdict(int)
            idx = (self._head - 1) % self._capacity
            for _ in range(self._size):
                ev = self._buffer[idx]
                if ev is not None:
                    source_total[ev.source_id] += 1
                    if ev.event_type == "error":
                        source_errors[ev.source_id] += 1
                idx = (idx - 1) % self._capacity
            return {
                sid: (source_errors.get(sid, 0) / total) if total else 0.0
                for sid, total in source_total.items()
            }
