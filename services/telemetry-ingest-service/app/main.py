"""
NeuroSphere Telemetry Ingest Service — Main Flask Application

Central telemetry collector for all NeuroSphere robotic surgery systems,
diagnostic devices, patient monitors, and edge gateways.

High-throughput design:
  • O(1) circular buffer for event storage
  • Batch ingestion endpoint for reduced HTTP overhead
  • Background thread computes rolling EPS every 5 s
  • Thread-safe data structures (single lock per operation)
"""

import json
import logging
import threading
import time
from typing import Any, Dict

from flask import Flask, Response, jsonify, request
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

from app.metrics import (
    TELEMETRY_BUFFER_SIZE,
    TELEMETRY_ERRORS_TOTAL,
    TELEMETRY_EVENTS_PER_SECOND,
    TELEMETRY_EVENTS_TOTAL,
    TELEMETRY_INGEST_LATENCY,
    TELEMETRY_SOURCES_ACTIVE,
)
from app.models import CircularBuffer, TelemetryEvent
from app.validators import validate_batch, validate_event, validate_events

# ---------------------------------------------------------------------------
# Structured JSON Logging
# ---------------------------------------------------------------------------
class JSONFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        log_obj: Dict[str, Any] = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "service": "telemetry-ingest-service",
            "message": record.getMessage(),
        }
        if record.exc_info and record.exc_info[0] is not None:
            log_obj["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_obj)


def _configure_logging() -> logging.Logger:
    logger = logging.getLogger("telemetry-ingest")
    logger.setLevel(logging.INFO)
    handler = logging.StreamHandler()
    handler.setFormatter(JSONFormatter())
    logger.addHandler(handler)
    return logger


# ---------------------------------------------------------------------------
# Background Stats Thread
# ---------------------------------------------------------------------------
class StatsComputer(threading.Thread):
    """
    Daemon thread that recalculates events-per-second and updates
    Prometheus gauges every ``interval`` seconds.
    """

    def __init__(self, buffer: CircularBuffer, interval: float = 5.0) -> None:
        super().__init__(daemon=True)
        self._buffer = buffer
        self._interval = interval
        self._prev_total = 0
        self._eps: float = 0.0
        self._running = True

    @property
    def eps(self) -> float:
        return self._eps

    def run(self) -> None:
        while self._running:
            time.sleep(self._interval)
            current_total = self._buffer.total_events
            self._eps = (current_total - self._prev_total) / self._interval
            self._prev_total = current_total

            # Update Prometheus gauges
            TELEMETRY_EVENTS_PER_SECOND.set(self._eps)
            TELEMETRY_BUFFER_SIZE.set(self._buffer.size)
            TELEMETRY_SOURCES_ACTIVE.set(len(self._buffer.active_sources()))

    def stop(self) -> None:
        self._running = False


# ---------------------------------------------------------------------------
# Flask App Factory
# ---------------------------------------------------------------------------
def create_app() -> Flask:
    """Application factory — creates, configures, and returns the Flask app."""

    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = 16 * 1024 * 1024  # 16 MiB request limit

    logger = _configure_logging()

    # Shared state ----------------------------------------------------------
    telemetry_buffer = CircularBuffer()
    stats = StatsComputer(telemetry_buffer)
    stats.start()

    _start_time = time.time()
    _is_ready = True  # flip to False if downstream dependency check fails

    # -- CORS ---------------------------------------------------------------
    @app.after_request
    def _add_cors(response: Response) -> Response:
        response.headers["Access-Control-Allow-Origin"] = "*"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
        response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        return response

    # -----------------------------------------------------------------------
    # Health / Readiness
    # -----------------------------------------------------------------------
    @app.route("/health", methods=["GET"])
    def health():
        """Liveness probe — always returns 200 if the process is alive."""
        return jsonify({
            "status": "healthy",
            "service": "telemetry-ingest-service",
            "uptime_seconds": round(time.time() - _start_time, 2),
        })

    @app.route("/ready", methods=["GET"])
    def ready():
        """Readiness probe — returns 200 when the service can accept traffic."""
        if _is_ready:
            return jsonify({
                "status": "ready",
                "buffer_utilization": f"{telemetry_buffer.size}/{telemetry_buffer._capacity}",
            })
        return jsonify({"status": "not_ready"}), 503

    # -----------------------------------------------------------------------
    # Prometheus Metrics
    # -----------------------------------------------------------------------
    @app.route("/metrics", methods=["GET"])
    def metrics():
        """Prometheus scrape endpoint."""
        return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

    # -----------------------------------------------------------------------
    # Telemetry Ingestion
    # -----------------------------------------------------------------------
    @app.route("/api/telemetry/ingest", methods=["POST"])
    def ingest():
        """
        Ingest one or more telemetry events.

        Accepts a JSON body that is either a single event object or an array
        of events.  Returns the number of events accepted.
        """
        with TELEMETRY_INGEST_LATENCY.time():
            body = request.get_json(silent=True)
            if body is None:
                TELEMETRY_ERRORS_TOTAL.inc()
                return jsonify({"error": "Invalid JSON body"}), 400

            # Normalise to list
            events_raw = body if isinstance(body, list) else [body]

            valid_dicts, errors = validate_events(events_raw)
            if errors:
                TELEMETRY_ERRORS_TOTAL.inc(len(errors))
                logger.warning("Validation failures: %d/%d events rejected",
                               len(errors), len(events_raw))

            # Convert to domain objects and store
            events = [
                TelemetryEvent(
                    source_id=e["source_id"],
                    source_type=e["source_type"],
                    event_type=e["event_type"],
                    timestamp=e["timestamp"],
                    payload=e["payload"],
                )
                for e in valid_dicts
            ]

            telemetry_buffer.append_many(events)

            # Bump Prometheus counters
            for ev in events:
                TELEMETRY_EVENTS_TOTAL.labels(
                    source_type=ev.source_type,
                    event_type=ev.event_type,
                ).inc()

            logger.info("Ingested %d events (%d rejected)", len(events), len(errors))

            return jsonify({
                "accepted": len(events),
                "rejected": len(errors),
                "errors": errors if errors else None,
            }), 202

    @app.route("/api/telemetry/ingest/batch", methods=["POST"])
    def ingest_batch():
        """
        Batch ingestion endpoint — accepts up to 1 000 events per request.

        Optimised for high-throughput producers (robot fleets, gateway
        aggregators) that buffer locally before flushing.
        """
        with TELEMETRY_INGEST_LATENCY.time():
            body = request.get_json(silent=True)
            if body is None:
                TELEMETRY_ERRORS_TOTAL.inc()
                return jsonify({"error": "Invalid JSON body"}), 400

            ok, msg = validate_batch(body)
            if not ok:
                TELEMETRY_ERRORS_TOTAL.inc()
                return jsonify({"error": msg}), 400

            valid_dicts, errors = validate_events(body)
            if errors:
                TELEMETRY_ERRORS_TOTAL.inc(len(errors))

            events = [
                TelemetryEvent(
                    source_id=e["source_id"],
                    source_type=e["source_type"],
                    event_type=e["event_type"],
                    timestamp=e["timestamp"],
                    payload=e["payload"],
                )
                for e in valid_dicts
            ]

            telemetry_buffer.append_many(events)

            for ev in events:
                TELEMETRY_EVENTS_TOTAL.labels(
                    source_type=ev.source_type,
                    event_type=ev.event_type,
                ).inc()

            logger.info("Batch ingested %d events (%d rejected)",
                        len(events), len(errors))

            return jsonify({
                "accepted": len(events),
                "rejected": len(errors),
                "total_in_batch": len(body),
                "errors": errors if errors else None,
            }), 202

    # -----------------------------------------------------------------------
    # Telemetry Queries
    # -----------------------------------------------------------------------
    @app.route("/api/telemetry/stats", methods=["GET"])
    def telemetry_stats():
        """Return real-time telemetry statistics."""
        total = telemetry_buffer.total_events
        error_rate = (
            telemetry_buffer.error_count / total if total > 0 else 0.0
        )
        return jsonify({
            "events_per_second": round(stats.eps, 2),
            "total_events_today": total,
            "events_by_type": dict(telemetry_buffer.events_by_type),
            "events_by_source": dict(telemetry_buffer.events_by_source_type),
            "error_rate": round(error_rate, 6),
            "buffer_size": telemetry_buffer.size,
            "buffer_capacity": telemetry_buffer._capacity,
        })

    @app.route("/api/telemetry/recent", methods=["GET"])
    def telemetry_recent():
        """Return the last 100 events, optionally filtered."""
        source_type = request.args.get("source_type")
        event_type = request.args.get("event_type")
        limit = min(int(request.args.get("limit", 100)), 500)

        events = telemetry_buffer.recent(
            n=limit,
            source_type=source_type,
            event_type=event_type,
        )
        return jsonify({
            "count": len(events),
            "filters": {
                "source_type": source_type,
                "event_type": event_type,
            },
            "events": events,
        })

    @app.route("/api/telemetry/errors", methods=["GET"])
    def telemetry_errors():
        """Return recent error events."""
        limit = min(int(request.args.get("limit", 100)), 500)
        errors = telemetry_buffer.recent_errors(n=limit)
        return jsonify({
            "count": len(errors),
            "total_errors": telemetry_buffer.error_count,
            "events": errors,
        })

    @app.route("/api/telemetry/health-summary", methods=["GET"])
    def telemetry_health_summary():
        """
        Aggregate health view across all telemetry sources.

        Reports which sources are actively sending, which have gone silent,
        and per-source error rates — useful for the ops dashboard.
        """
        active = telemetry_buffer.active_sources()
        silent = telemetry_buffer.silent_sources()
        error_rates = telemetry_buffer.error_rates_by_source()

        return jsonify({
            "sources_reporting": len(active),
            "sources_silent": len(silent),
            "active_source_ids": active,
            "silent_source_ids": silent,
            "error_rates_by_source": error_rates,
            "overall_buffer_health": "healthy" if len(silent) == 0 else "degraded",
        })

    return app


# ---------------------------------------------------------------------------
# Dev entry-point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=5002, debug=True)
