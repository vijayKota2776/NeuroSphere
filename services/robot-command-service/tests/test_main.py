"""
Unit tests for the NeuroSphere Robot Command Service.

Covers all major endpoints:  health, readiness, fleet status,
robot detail, command dispatch, heartbeat, and metrics.
"""

import json
import pytest

from app.main import create_app


@pytest.fixture
def client():
    """Create a Flask test client with a fresh fleet each run."""
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


# ------------------------------------------------------------------
# 1. Health & readiness
# ------------------------------------------------------------------

class TestHealthEndpoints:
    def test_health_returns_200(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["status"] == "healthy"
        assert data["service"] == "robot-command-service"

    def test_ready_returns_200_when_fleet_initialised(self, client):
        resp = client.get("/ready")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["status"] == "ready"
        assert data["fleet_size"] == 10
        assert data["online_robots"] > 0


# ------------------------------------------------------------------
# 2. Fleet status
# ------------------------------------------------------------------

class TestFleetStatus:
    def test_fleet_status_returns_all_robots(self, client):
        resp = client.get("/api/robots/status")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["fleet_size"] == 10
        assert len(data["robots"]) == 10
        # Spot-check a known robot
        ids = [r["robot_id"] for r in data["robots"]]
        assert "NSR-DA-VINCI-001" in ids

    def test_fleet_status_contains_expected_fields(self, client):
        resp = client.get("/api/robots/status")
        robot = resp.get_json()["robots"][0]
        for key in ("robot_id", "name", "type", "status", "last_heartbeat",
                     "current_procedure", "battery_level", "hospital", "department"):
            assert key in robot, f"Missing field: {key}"


# ------------------------------------------------------------------
# 3. Robot detail
# ------------------------------------------------------------------

class TestRobotDetail:
    def test_get_existing_robot(self, client):
        resp = client.get("/api/robots/NSR-DA-VINCI-001")
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["robot_id"] == "NSR-DA-VINCI-001"
        assert data["name"] == "Da Vinci Xi Alpha"
        assert data["type"] == "surgical_arm"
        assert data["hospital"] == "Massachusetts General Hospital"
        assert 0 <= data["battery_level"] <= 100

    def test_get_nonexistent_robot_returns_404(self, client):
        resp = client.get("/api/robots/NSR-DOES-NOT-EXIST")
        assert resp.status_code == 404
        assert "not found" in resp.get_json()["error"]


# ------------------------------------------------------------------
# 4. Command endpoint
# ------------------------------------------------------------------

class TestCommandEndpoint:
    def test_valid_move_command(self, client):
        payload = {
            "robot_id": "NSR-DA-VINCI-001",
            "command": "move",
            "parameters": {"target_position": "patient_table_alpha"},
        }
        resp = client.post(
            "/api/robots/command",
            data=json.dumps(payload),
            content_type="application/json",
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["status"] == "success"
        assert data["command"] == "move"
        assert "command_id" in data
        assert data["latency_ms"] > 0

    def test_start_and_stop_procedure(self, client):
        # Start
        start_payload = {
            "robot_id": "NSR-MAKO-001",
            "command": "start_procedure",
            "parameters": {"procedure": "total_knee_arthroplasty"},
        }
        resp = client.post(
            "/api/robots/command",
            data=json.dumps(start_payload),
            content_type="application/json",
        )
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "success"

        # Verify robot is now busy
        detail = client.get("/api/robots/NSR-MAKO-001").get_json()
        assert detail["status"] == "busy"
        assert detail["current_procedure"] == "total_knee_arthroplasty"

        # Stop
        stop_payload = {"robot_id": "NSR-MAKO-001", "command": "stop_procedure"}
        resp = client.post(
            "/api/robots/command",
            data=json.dumps(stop_payload),
            content_type="application/json",
        )
        assert resp.status_code == 200
        assert resp.get_json()["status"] == "success"

    def test_emergency_halt(self, client):
        payload = {"robot_id": "NSR-ENDO-001", "command": "emergency_halt"}
        resp = client.post(
            "/api/robots/command",
            data=json.dumps(payload),
            content_type="application/json",
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["status"] == "success"
        assert "EMERGENCY HALT" in data["detail"]

        # Robot should now be in emergency_halt state
        detail = client.get("/api/robots/NSR-ENDO-001").get_json()
        assert detail["status"] == "emergency_halt"

    def test_invalid_command_returns_400(self, client):
        payload = {"robot_id": "NSR-DA-VINCI-001", "command": "self_destruct"}
        resp = client.post(
            "/api/robots/command",
            data=json.dumps(payload),
            content_type="application/json",
        )
        assert resp.status_code == 400
        assert "Invalid command" in resp.get_json()["error"]

    def test_missing_body_returns_400(self, client):
        resp = client.post("/api/robots/command", content_type="application/json")
        assert resp.status_code == 400

    def test_unknown_robot_returns_404(self, client):
        payload = {"robot_id": "NSR-PHANTOM-999", "command": "move"}
        resp = client.post(
            "/api/robots/command",
            data=json.dumps(payload),
            content_type="application/json",
        )
        assert resp.status_code == 404

    def test_cannot_start_procedure_on_halted_robot(self, client):
        # Halt first
        halt = {"robot_id": "NSR-MICRO-001", "command": "emergency_halt"}
        client.post("/api/robots/command", data=json.dumps(halt), content_type="application/json")

        # Try to start a procedure
        start = {"robot_id": "NSR-MICRO-001", "command": "start_procedure"}
        resp = client.post("/api/robots/command", data=json.dumps(start), content_type="application/json")
        assert resp.status_code == 409
        assert resp.get_json()["status"] == "rejected"


# ------------------------------------------------------------------
# 5. Heartbeat
# ------------------------------------------------------------------

class TestHeartbeat:
    def test_heartbeat_returns_all_robots(self, client):
        resp = client.get("/api/robots/heartbeat")
        assert resp.status_code == 200
        data = resp.get_json()
        assert len(data["heartbeat"]) == 10
        # Each entry should have expected keys
        for rid, info in data["heartbeat"].items():
            assert "online" in info
            assert "last_heartbeat" in info
            assert "status" in info
            assert "battery_level" in info


# ------------------------------------------------------------------
# 6. Metrics
# ------------------------------------------------------------------

class TestMetrics:
    def test_metrics_endpoint_returns_prometheus_format(self, client):
        # Fire a command first so counters are non-zero
        payload = {"robot_id": "NSR-DA-VINCI-002", "command": "calibrate"}
        client.post("/api/robots/command", data=json.dumps(payload), content_type="application/json")

        resp = client.get("/metrics")
        assert resp.status_code == 200
        body = resp.data.decode()
        assert "robot_command_latency_seconds" in body
        assert "robot_commands_total" in body
        assert "robot_heartbeat_status" in body
        assert "robot_battery_level" in body
        assert "active_procedures_total" in body
