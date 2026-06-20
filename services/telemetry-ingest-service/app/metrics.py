"""
NeuroSphere Telemetry Ingest Service — Prometheus Metrics

All custom healthcare-specific Prometheus metrics are defined here so they
can be imported by the application and the background stats thread.
"""

from prometheus_client import Counter, Gauge, Histogram

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

TELEMETRY_EVENTS_TOTAL = Counter(
    "telemetry_events_total",
    "Total telemetry events ingested, labelled by source and event type",
    ["source_type", "event_type"],
)

TELEMETRY_ERRORS_TOTAL = Counter(
    "telemetry_errors_total",
    "Total failed ingestion attempts (validation failures, malformed payloads)",
)

# ---------------------------------------------------------------------------
# Gauges
# ---------------------------------------------------------------------------

TELEMETRY_EVENTS_PER_SECOND = Gauge(
    "telemetry_events_per_second",
    "Rolling ingestion rate computed every 5 seconds",
)

TELEMETRY_BUFFER_SIZE = Gauge(
    "telemetry_buffer_size",
    "Current number of events stored in the in-memory circular buffer",
)

TELEMETRY_SOURCES_ACTIVE = Gauge(
    "telemetry_sources_active",
    "Number of telemetry sources that reported within the last 60 seconds",
)

# ---------------------------------------------------------------------------
# Histograms
# ---------------------------------------------------------------------------

TELEMETRY_INGEST_LATENCY = Histogram(
    "telemetry_ingest_latency_seconds",
    "Time to validate and store a telemetry ingestion request",
    buckets=(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0),
)
