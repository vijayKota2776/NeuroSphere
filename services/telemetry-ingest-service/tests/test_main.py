"""
NeuroSphere Telemetry Ingest Service — Unit Tests

Covers:
  1. Single event ingestion (happy path)
  2. Batch ingestion with mixed valid/invalid events
  3. Validation rejection of missing fields
  4. Validation rejection of invalid source_type / event_type
  5. GET /api/telemetry/stats returns expected shape
  6. GET /api/telemetry/recent with filtering
  7. GET /api/telemetry/errors returns only error events
  8. GET /api/telemetry/health-summary response shape
  9. Health & readiness probes
  10. Batch size limit enforcement
"""

import json
import pytest

from app.main import create_app


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
@pytest.fixture()
def client():
    """Create a test client with a fresh app for every test."""
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def _make_event(**overrides):
    """Helper: build a valid telemetry event dict with optional overrides."""
    base = {
        "source_id": "robot-arm-alpha-7",
        "source_type": "robot",
        "event_type": "heartbeat",
        "timestamp": "2026-06-19T18:00:00Z",
        "payload": {
            "joint_angles": [0.0, -15.3, 42.1, 0.0, 7.8, -3.2],
            "force_torque_N": 1.25,
            "operating_room": "OR-3",
        },
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# 1. Single event ingestion — happy path
# ---------------------------------------------------------------------------
def test_ingest_single_event(client):
    event = _make_event()
    resp = client.post(
        "/api/telemetry/ingest",
        data=json.dumps(event),
        content_type="application/json",
    )
    assert resp.status_code == 202
    body = resp.get_json()
    assert body["accepted"] == 1
    assert body["rejected"] == 0


# ---------------------------------------------------------------------------
# 2. Batch ingestion — mixed valid and invalid events
# ---------------------------------------------------------------------------
def test_ingest_batch_mixed(client):
    events = [
        _make_event(source_id="robot-arm-alpha-7"),
        _make_event(source_id="patient-monitor-12", source_type="patient_monitor",
                    event_type="metric",
                    payload={"heart_rate_bpm": 72, "spo2_pct": 98.5}),
        # invalid — bad source_type
        _make_event(source_id="bad-source", source_type="unknown_device"),
        _make_event(source_id="gw-east-1", source_type="gateway",
                    event_type="status_update",
                    payload={"uplink_latency_ms": 4.2}),
    ]
    resp = client.post(
        "/api/telemetry/ingest/batch",
        data=json.dumps(events),
        content_type="application/json",
    )
    assert resp.status_code == 202
    body = resp.get_json()
    assert body["accepted"] == 3
    assert body["rejected"] == 1
    assert body["total_in_batch"] == 4


# ---------------------------------------------------------------------------
# 3. Validation rejects missing fields
# ---------------------------------------------------------------------------
def test_validation_missing_fields(client):
    incomplete = {"source_id": "robot-arm-alpha-7"}  # missing everything else
    resp = client.post(
        "/api/telemetry/ingest",
        data=json.dumps(incomplete),
        content_type="application/json",
    )
    assert resp.status_code == 202
    body = resp.get_json()
    assert body["accepted"] == 0
    assert body["rejected"] == 1


# ---------------------------------------------------------------------------
# 4. Validation rejects invalid enum values
# ---------------------------------------------------------------------------
def test_validation_invalid_enums(client):
    bad_event = _make_event(source_type="microwave", event_type="explode")
    resp = client.post(
        "/api/telemetry/ingest",
        data=json.dumps(bad_event),
        content_type="application/json",
    )
    body = resp.get_json()
    assert body["accepted"] == 0
    assert body["rejected"] == 1
    assert "source_type" in body["errors"][0]["error"]


# ---------------------------------------------------------------------------
# 5. GET /api/telemetry/stats returns expected shape
# ---------------------------------------------------------------------------
def test_stats_endpoint(client):
    # Ingest a few events first
    for etype in ("heartbeat", "metric", "error"):
        client.post(
            "/api/telemetry/ingest",
            data=json.dumps(_make_event(event_type=etype)),
            content_type="application/json",
        )

    resp = client.get("/api/telemetry/stats")
    assert resp.status_code == 200
    body = resp.get_json()
    assert "events_per_second" in body
    assert body["total_events_today"] == 3
    assert "heartbeat" in body["events_by_type"]
    assert body["buffer_size"] == 3


# ---------------------------------------------------------------------------
# 6. GET /api/telemetry/recent with filtering
# ---------------------------------------------------------------------------
def test_recent_with_filter(client):
    # Ingest events of different types
    client.post(
        "/api/telemetry/ingest",
        data=json.dumps(_make_event(event_type="heartbeat")),
        content_type="application/json",
    )
    client.post(
        "/api/telemetry/ingest",
        data=json.dumps(_make_event(event_type="alert",
                                     payload={"severity": "critical",
                                              "message": "Instrument collision risk"})),
        content_type="application/json",
    )

    # Unfiltered
    resp = client.get("/api/telemetry/recent")
    assert resp.get_json()["count"] == 2

    # Filtered by event_type
    resp = client.get("/api/telemetry/recent?event_type=alert")
    body = resp.get_json()
    assert body["count"] == 1
    assert body["events"][0]["event_type"] == "alert"


# ---------------------------------------------------------------------------
# 7. GET /api/telemetry/errors returns only error events
# ---------------------------------------------------------------------------
def test_errors_endpoint(client):
    client.post(
        "/api/telemetry/ingest",
        data=json.dumps(_make_event(event_type="heartbeat")),
        content_type="application/json",
    )
    client.post(
        "/api/telemetry/ingest",
        data=json.dumps(_make_event(
            event_type="error",
            payload={
                "error_code": "ESTOP_ACTIVATED",
                "subsystem": "motion_controller",
                "message": "Emergency stop triggered by proximity sensor",
            },
        )),
        content_type="application/json",
    )

    resp = client.get("/api/telemetry/errors")
    body = resp.get_json()
    assert body["count"] == 1
    assert body["total_errors"] == 1
    assert body["events"][0]["event_type"] == "error"


# ---------------------------------------------------------------------------
# 8. GET /api/telemetry/health-summary response shape
# ---------------------------------------------------------------------------
def test_health_summary(client):
    client.post(
        "/api/telemetry/ingest",
        data=json.dumps(_make_event(source_id="robot-arm-alpha-7")),
        content_type="application/json",
    )
    resp = client.get("/api/telemetry/health-summary")
    assert resp.status_code == 200
    body = resp.get_json()
    assert "sources_reporting" in body
    assert "sources_silent" in body
    assert "error_rates_by_source" in body
    assert "robot-arm-alpha-7" in body["active_source_ids"]


# ---------------------------------------------------------------------------
# 9. Health and readiness probes
# ---------------------------------------------------------------------------
def test_health_probe(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "healthy"
    assert body["service"] == "telemetry-ingest-service"
    assert "uptime_seconds" in body


def test_readiness_probe(client):
    resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ready"


# ---------------------------------------------------------------------------
# 10. Batch size limit enforcement
# ---------------------------------------------------------------------------
def test_batch_exceeds_limit(client):
    huge_batch = [_make_event(source_id=f"dev-{i}") for i in range(1001)]
    resp = client.post(
        "/api/telemetry/ingest/batch",
        data=json.dumps(huge_batch),
        content_type="application/json",
    )
    assert resp.status_code == 400
    assert "maximum size" in resp.get_json()["error"].lower()


# ---------------------------------------------------------------------------
# 11. Metrics endpoint returns Prometheus format
# ---------------------------------------------------------------------------
def test_metrics_endpoint(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"telemetry_events_total" in resp.data
    assert b"telemetry_buffer_size" in resp.data
