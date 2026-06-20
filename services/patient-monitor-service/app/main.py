"""
Patient Monitor Service — NeuroSphere Medical Technologies
Main Flask application for real-time patient vitals monitoring.

Provides REST APIs for patient registration, vitals tracking,
alert management, and dashboard views with Prometheus metrics.
"""

import os
import json
import logging
from flask import Flask, jsonify, request
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

from app.models import Patient, PatientRegistry, DEFAULT_PATIENTS
from app.vitals_simulator import VitalsSimulator
from app import metrics as prom_metrics

# ──────────────────────────────────────────────
# Logging Configuration
# ──────────────────────────────────────────────

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_record = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "service": "patient-monitor-service",
            "message": record.getMessage(),
            "module": record.module,
        }
        if record.exc_info:
            log_record["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_record)

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────
# App Factory
# ──────────────────────────────────────────────

def create_app():
    app = Flask(__name__)

    # Initialize patient registry
    registry = PatientRegistry()

    # Register default patients
    for pdata in DEFAULT_PATIENTS:
        patient = Patient(**pdata)
        registry.register(patient)
    logger.info(f"Initialized {len(registry.patients)} patients for monitoring")

    # Start vitals simulator
    anomaly_rate = float(os.environ.get("ANOMALY_RATE", "0.05"))
    update_interval = int(os.environ.get("VITALS_UPDATE_INTERVAL", "3"))
    simulator = VitalsSimulator(registry, anomaly_rate=anomaly_rate, update_interval=update_interval)
    simulator.start()

    # ──────────────────────────────────────────
    # Health & Readiness Endpoints
    # ──────────────────────────────────────────

    @app.route("/health", methods=["GET"])
    def health():
        """Liveness probe — service is running."""
        return jsonify({"status": "healthy", "service": "patient-monitor-service"}), 200

    @app.route("/ready", methods=["GET"])
    def ready():
        """Readiness probe — service is ready to accept traffic."""
        patients_loaded = len(registry.patients) > 0
        simulator_running = simulator._running
        if patients_loaded and simulator_running:
            return jsonify({
                "status": "ready",
                "patients_loaded": len(registry.patients),
                "simulator_active": True,
            }), 200
        return jsonify({
            "status": "not_ready",
            "patients_loaded": len(registry.patients),
            "simulator_active": simulator_running,
        }), 503

    # ──────────────────────────────────────────
    # Prometheus Metrics Endpoint
    # ──────────────────────────────────────────

    @app.route("/metrics", methods=["GET"])
    def metrics():
        """Prometheus metrics endpoint."""
        return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

    # ──────────────────────────────────────────
    # Patient Vitals Endpoints
    # ──────────────────────────────────────────

    @app.route("/api/patients/vitals", methods=["GET"])
    def get_all_vitals():
        """Return current vitals for all monitored patients."""
        patients_vitals = []
        for patient in registry.get_all():
            patients_vitals.append({
                "patient_id": patient.patient_id,
                "name": patient.name,
                "ward": patient.ward,
                "status": patient.status,
                "vitals": patient.current_vitals,
            })
        return jsonify({
            "total_patients": len(patients_vitals),
            "patients": patients_vitals,
            "timestamp": __import__("datetime").datetime.utcnow().isoformat() + "Z",
        }), 200

    @app.route("/api/patients/vitals/<patient_id>", methods=["GET"])
    def get_patient_vitals(patient_id):
        """Return vitals for a specific patient with history."""
        patient = registry.get(patient_id)
        if not patient:
            return jsonify({"error": "Patient not found", "patient_id": patient_id}), 404
        return jsonify(patient.to_detail_dict()), 200

    # ──────────────────────────────────────────
    # Alert Endpoints
    # ──────────────────────────────────────────

    @app.route("/api/patients/alerts", methods=["GET"])
    def get_alerts():
        """Return active alerts with optional severity filter."""
        severity = request.args.get("severity")
        alerts = registry.get_active_alerts()
        if severity:
            alerts = [a for a in alerts if a["severity"] == severity.upper()]
        return jsonify({
            "total_active_alerts": len(alerts),
            "alerts": alerts[:50],  # Return latest 50
        }), 200

    # ──────────────────────────────────────────
    # Patient Registration
    # ──────────────────────────────────────────

    @app.route("/api/patients/register", methods=["POST"])
    def register_patient():
        """Register a new patient for monitoring."""
        data = request.get_json()
        if not data:
            return jsonify({"error": "Request body required"}), 400

        required_fields = ["name", "age", "ward", "condition"]
        missing = [f for f in required_fields if f not in data]
        if missing:
            return jsonify({"error": f"Missing required fields: {missing}"}), 400

        patient = Patient(
            name=data["name"],
            age=data["age"],
            ward=data["ward"],
            condition=data["condition"],
            assigned_robot_id=data.get("assigned_robot_id"),
        )
        registry.register(patient)
        prom_metrics.active_monitors.set(len(registry.patients))
        logger.info(f"Patient registered: {patient.name} ({patient.patient_id}) in {patient.ward}")

        return jsonify({
            "message": "Patient registered for monitoring",
            "patient": patient.to_dict(),
        }), 201

    # ──────────────────────────────────────────
    # Patient History
    # ──────────────────────────────────────────

    @app.route("/api/patients/history/<patient_id>", methods=["GET"])
    def get_patient_history(patient_id):
        """Return vitals history for a patient."""
        patient = registry.get(patient_id)
        if not patient:
            return jsonify({"error": "Patient not found", "patient_id": patient_id}), 404

        limit = request.args.get("limit", 50, type=int)
        history = list(patient.vitals_history)[-limit:]

        return jsonify({
            "patient_id": patient_id,
            "name": patient.name,
            "ward": patient.ward,
            "total_readings": len(patient.vitals_history),
            "history": history,
        }), 200

    # ──────────────────────────────────────────
    # Dashboard
    # ──────────────────────────────────────────

    @app.route("/api/patients/dashboard", methods=["GET"])
    def dashboard():
        """Return summary dashboard data for monitoring overview."""
        summary = registry.get_dashboard_summary()
        return jsonify(summary), 200

    return app


# ──────────────────────────────────────────────
# Entry Point
# ──────────────────────────────────────────────

app = create_app()

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5001))
    logger.info(f"Patient Monitor Service starting on port {port}")
    app.run(host="0.0.0.0", port=port, debug=False)
