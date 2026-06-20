"""
Unit tests for Patient Monitor Service.
Tests all major endpoints and vitals simulation logic.
"""

import sys
import os
import json
import pytest

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.main import create_app
from app.vitals_simulator import generate_vitals, check_thresholds


@pytest.fixture
def client():
    """Create test client."""
    app = create_app()
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


class TestHealthEndpoints:
    """Test health and readiness probes."""

    def test_health_endpoint(self, client):
        """Test liveness probe returns 200."""
        response = client.get("/health")
        assert response.status_code == 200
        data = response.get_json()
        assert data["status"] == "healthy"
        assert data["service"] == "patient-monitor-service"

    def test_ready_endpoint(self, client):
        """Test readiness probe returns 200 when patients loaded."""
        response = client.get("/ready")
        assert response.status_code == 200
        data = response.get_json()
        assert data["status"] == "ready"
        assert data["patients_loaded"] >= 15


class TestVitalsEndpoints:
    """Test patient vitals API endpoints."""

    def test_get_all_vitals(self, client):
        """Test fetching vitals for all patients."""
        response = client.get("/api/patients/vitals")
        assert response.status_code == 200
        data = response.get_json()
        assert data["total_patients"] >= 15
        assert "patients" in data

    def test_get_patient_vitals_not_found(self, client):
        """Test fetching vitals for non-existent patient."""
        response = client.get("/api/patients/vitals/nonexistent")
        assert response.status_code == 404


class TestAlertEndpoints:
    """Test alert management endpoints."""

    def test_get_alerts(self, client):
        """Test fetching active alerts."""
        response = client.get("/api/patients/alerts")
        assert response.status_code == 200
        data = response.get_json()
        assert "total_active_alerts" in data
        assert "alerts" in data

    def test_get_alerts_filtered(self, client):
        """Test fetching alerts with severity filter."""
        response = client.get("/api/patients/alerts?severity=CRITICAL")
        assert response.status_code == 200


class TestPatientRegistration:
    """Test patient registration endpoint."""

    def test_register_patient(self, client):
        """Test registering a new patient."""
        new_patient = {
            "name": "Test Patient",
            "age": 45,
            "ward": "ICU",
            "condition": "Test condition",
            "assigned_robot_id": "ROBO-TEST-001",
        }
        response = client.post(
            "/api/patients/register",
            data=json.dumps(new_patient),
            content_type="application/json",
        )
        assert response.status_code == 201
        data = response.get_json()
        assert data["patient"]["name"] == "Test Patient"
        assert data["patient"]["ward"] == "ICU"

    def test_register_patient_missing_fields(self, client):
        """Test registration fails with missing required fields."""
        response = client.post(
            "/api/patients/register",
            data=json.dumps({"name": "Incomplete"}),
            content_type="application/json",
        )
        assert response.status_code == 400


class TestDashboard:
    """Test dashboard endpoint."""

    def test_dashboard(self, client):
        """Test dashboard summary data."""
        response = client.get("/api/patients/dashboard")
        assert response.status_code == 200
        data = response.get_json()
        assert "total_patients" in data
        assert "critical_count" in data
        assert "stable_count" in data
        assert "alerts_today" in data


class TestVitalsSimulation:
    """Test vitals generation logic."""

    def test_generate_normal_vitals(self):
        """Test normal vitals are within expected ranges."""
        vitals = generate_vitals(ward="default")
        assert 40 <= vitals["heart_rate"] <= 200
        assert 60 <= vitals["blood_pressure_systolic"] <= 250
        assert 50 <= vitals["spo2"] <= 100
        assert 34.0 <= vitals["temperature"] <= 42.0

    def test_generate_anomaly_vitals(self):
        """Test anomaly injection works."""
        # Run multiple times to ensure at least one anomaly is generated
        anomaly_found = False
        for _ in range(20):
            vitals = generate_vitals(ward="ICU", inject_anomaly=True)
            if "_anomaly" in vitals:
                anomaly_found = True
                break
        assert anomaly_found, "Anomaly should be injected when inject_anomaly=True"

    def test_threshold_check_normal(self):
        """Test no alerts for normal vitals."""
        normal_vitals = {
            "heart_rate": 72,
            "spo2": 98,
            "temperature": 36.8,
            "blood_pressure_systolic": 120,
            "respiratory_rate": 16,
        }
        alerts = check_thresholds("P001", "Test Patient", "General", normal_vitals)
        assert len(alerts) == 0

    def test_threshold_check_critical(self):
        """Test critical alert for dangerous vitals."""
        critical_vitals = {
            "heart_rate": 180,
            "spo2": 75,
            "temperature": 40.5,
            "blood_pressure_systolic": 200,
            "respiratory_rate": 35,
        }
        alerts = check_thresholds("P001", "Test Patient", "ICU", critical_vitals)
        assert len(alerts) > 0
        assert all(a.severity == "CRITICAL" for a in alerts)


class TestMetrics:
    """Test Prometheus metrics endpoint."""

    def test_metrics_endpoint(self, client):
        """Test Prometheus metrics are exposed."""
        response = client.get("/metrics")
        assert response.status_code == 200
        content = response.data.decode("utf-8")
        assert "patient_vitals_anomalies_total" in content or "active_patient_monitors" in content
