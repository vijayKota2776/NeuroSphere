"""
Realistic patient vitals simulation engine.
Generates medically accurate vital signs with configurable anomaly rates.
Supports different baseline vitals per ward and condition severity.
"""

import random
import time
import threading
import logging
from datetime import datetime

from app.models import Alert
from app import metrics as prom_metrics

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────
# Normal vital sign ranges by ward context
# ──────────────────────────────────────────────

VITAL_RANGES = {
    "default": {
        "heart_rate": (60, 100),
        "blood_pressure_systolic": (110, 130),
        "blood_pressure_diastolic": (70, 85),
        "spo2": (95, 100),
        "temperature": (36.2, 37.2),
        "respiratory_rate": (12, 20),
    },
    "ICU": {
        "heart_rate": (55, 110),
        "blood_pressure_systolic": (100, 140),
        "blood_pressure_diastolic": (60, 90),
        "spo2": (92, 100),
        "temperature": (36.0, 38.0),
        "respiratory_rate": (10, 24),
    },
    "Cardiac": {
        "heart_rate": (50, 120),
        "blood_pressure_systolic": (100, 150),
        "blood_pressure_diastolic": (60, 95),
        "spo2": (93, 100),
        "temperature": (36.2, 37.5),
        "respiratory_rate": (12, 22),
    },
    "Pediatric": {
        "heart_rate": (70, 120),
        "blood_pressure_systolic": (90, 110),
        "blood_pressure_diastolic": (55, 75),
        "spo2": (95, 100),
        "temperature": (36.5, 37.5),
        "respiratory_rate": (16, 28),
    },
}

# ──────────────────────────────────────────────
# Anomaly thresholds (trigger alerts when exceeded)
# ──────────────────────────────────────────────

CRITICAL_THRESHOLDS = {
    "heart_rate_high": 150,
    "heart_rate_low": 40,
    "spo2_low": 88,
    "temperature_high": 39.5,
    "systolic_high": 180,
    "systolic_low": 80,
    "respiratory_rate_high": 30,
    "respiratory_rate_low": 8,
}

WARNING_THRESHOLDS = {
    "heart_rate_high": 120,
    "heart_rate_low": 50,
    "spo2_low": 92,
    "temperature_high": 38.5,
    "systolic_high": 160,
    "systolic_low": 90,
    "respiratory_rate_high": 25,
    "respiratory_rate_low": 10,
}

# ──────────────────────────────────────────────
# Anomaly simulation profiles
# ──────────────────────────────────────────────

ANOMALY_PROFILES = [
    {
        "type": "tachycardia",
        "description": "Sudden increase in heart rate",
        "vital": "heart_rate",
        "range": (130, 180),
    },
    {
        "type": "bradycardia",
        "description": "Dangerously low heart rate",
        "vital": "heart_rate",
        "range": (30, 45),
    },
    {
        "type": "hypoxemia",
        "description": "Critical drop in blood oxygen saturation",
        "vital": "spo2",
        "range": (75, 88),
    },
    {
        "type": "hypertensive_crisis",
        "description": "Severe elevation in blood pressure",
        "vital": "blood_pressure_systolic",
        "range": (180, 220),
    },
    {
        "type": "hypotension",
        "description": "Dangerously low blood pressure",
        "vital": "blood_pressure_systolic",
        "range": (60, 80),
    },
    {
        "type": "hyperthermia",
        "description": "High fever detected",
        "vital": "temperature",
        "range": (39.0, 41.0),
    },
    {
        "type": "respiratory_distress",
        "description": "Abnormal respiratory rate indicating distress",
        "vital": "respiratory_rate",
        "range": (28, 40),
    },
]


def generate_vitals(ward="default", inject_anomaly=False):
    """
    Generate a single set of realistic vital signs.
    
    Args:
        ward: Hospital ward for context-appropriate ranges
        inject_anomaly: If True, one vital will be pushed out of normal range
    
    Returns:
        dict of vital signs with timestamp
    """
    ranges = VITAL_RANGES.get(ward, VITAL_RANGES["default"])

    vitals = {
        "heart_rate": round(random.uniform(*ranges["heart_rate"])),
        "blood_pressure_systolic": round(random.uniform(*ranges["blood_pressure_systolic"])),
        "blood_pressure_diastolic": round(random.uniform(*ranges["blood_pressure_diastolic"])),
        "spo2": round(random.uniform(*ranges["spo2"]), 1),
        "temperature": round(random.uniform(*ranges["temperature"]), 1),
        "respiratory_rate": round(random.uniform(*ranges["respiratory_rate"])),
        "timestamp": datetime.utcnow().isoformat() + "Z",
    }

    # Format blood pressure as readable string too
    vitals["blood_pressure"] = f"{vitals['blood_pressure_systolic']}/{vitals['blood_pressure_diastolic']}"

    if inject_anomaly:
        profile = random.choice(ANOMALY_PROFILES)
        anomaly_value = round(random.uniform(*profile["range"]), 1)
        vitals[profile["vital"]] = anomaly_value
        vitals["_anomaly"] = {
            "type": profile["type"],
            "description": profile["description"],
            "vital": profile["vital"],
            "value": anomaly_value,
        }

    return vitals


def check_thresholds(patient_id, patient_name, ward, vitals):
    """
    Check vital signs against clinical thresholds and generate alerts.
    
    Returns:
        list of Alert objects for any threshold violations
    """
    alerts = []

    hr = vitals.get("heart_rate", 0)
    spo2 = vitals.get("spo2", 100)
    temp = vitals.get("temperature", 37.0)
    systolic = vitals.get("blood_pressure_systolic", 120)
    rr = vitals.get("respiratory_rate", 16)

    # Critical checks
    if hr >= CRITICAL_THRESHOLDS["heart_rate_high"]:
        alerts.append(Alert(
            patient_id, "CRITICAL", "tachycardia",
            f"CRITICAL: {patient_name} - Heart rate critically elevated at {hr} bpm (Ward: {ward})",
            "heart_rate", hr
        ))
    elif hr <= CRITICAL_THRESHOLDS["heart_rate_low"]:
        alerts.append(Alert(
            patient_id, "CRITICAL", "bradycardia",
            f"CRITICAL: {patient_name} - Heart rate critically low at {hr} bpm (Ward: {ward})",
            "heart_rate", hr
        ))
    elif hr >= WARNING_THRESHOLDS["heart_rate_high"]:
        alerts.append(Alert(
            patient_id, "WARNING", "elevated_heart_rate",
            f"WARNING: {patient_name} - Elevated heart rate at {hr} bpm (Ward: {ward})",
            "heart_rate", hr
        ))

    if spo2 <= CRITICAL_THRESHOLDS["spo2_low"]:
        alerts.append(Alert(
            patient_id, "CRITICAL", "hypoxemia",
            f"CRITICAL: {patient_name} - SpO2 critically low at {spo2}% (Ward: {ward})",
            "spo2", spo2
        ))
    elif spo2 <= WARNING_THRESHOLDS["spo2_low"]:
        alerts.append(Alert(
            patient_id, "WARNING", "low_spo2",
            f"WARNING: {patient_name} - SpO2 below normal at {spo2}% (Ward: {ward})",
            "spo2", spo2
        ))

    if temp >= CRITICAL_THRESHOLDS["temperature_high"]:
        alerts.append(Alert(
            patient_id, "CRITICAL", "hyperthermia",
            f"CRITICAL: {patient_name} - High fever at {temp}°C (Ward: {ward})",
            "temperature", temp
        ))
    elif temp >= WARNING_THRESHOLDS["temperature_high"]:
        alerts.append(Alert(
            patient_id, "WARNING", "elevated_temperature",
            f"WARNING: {patient_name} - Elevated temperature at {temp}°C (Ward: {ward})",
            "temperature", temp
        ))

    if systolic >= CRITICAL_THRESHOLDS["systolic_high"]:
        alerts.append(Alert(
            patient_id, "CRITICAL", "hypertensive_crisis",
            f"CRITICAL: {patient_name} - Hypertensive crisis, systolic at {systolic} mmHg (Ward: {ward})",
            "blood_pressure_systolic", systolic
        ))
    elif systolic <= CRITICAL_THRESHOLDS["systolic_low"]:
        alerts.append(Alert(
            patient_id, "CRITICAL", "hypotension",
            f"CRITICAL: {patient_name} - Severe hypotension, systolic at {systolic} mmHg (Ward: {ward})",
            "blood_pressure_systolic", systolic
        ))

    if rr >= CRITICAL_THRESHOLDS["respiratory_rate_high"]:
        alerts.append(Alert(
            patient_id, "CRITICAL", "respiratory_distress",
            f"CRITICAL: {patient_name} - Respiratory distress, rate at {rr} breaths/min (Ward: {ward})",
            "respiratory_rate", rr
        ))
    elif rr <= CRITICAL_THRESHOLDS["respiratory_rate_low"]:
        alerts.append(Alert(
            patient_id, "WARNING", "low_respiratory_rate",
            f"WARNING: {patient_name} - Low respiratory rate at {rr} breaths/min (Ward: {ward})",
            "respiratory_rate", rr
        ))

    return alerts


class VitalsSimulator:
    """
    Background thread that continuously updates patient vitals.
    Simulates realistic vital sign fluctuations with configurable anomaly rate.
    """

    def __init__(self, registry, anomaly_rate=0.05, update_interval=3):
        self.registry = registry
        self.anomaly_rate = anomaly_rate
        self.update_interval = update_interval
        self._running = False
        self._thread = None

    def start(self):
        """Start the vitals simulation background thread."""
        self._running = True
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        logger.info(
            f"VitalsSimulator started: {len(self.registry.patients)} patients, "
            f"anomaly_rate={self.anomaly_rate}, interval={self.update_interval}s"
        )

    def stop(self):
        """Stop the vitals simulation."""
        self._running = False
        if self._thread:
            self._thread.join(timeout=5)

    def _run(self):
        """Main simulation loop."""
        while self._running:
            try:
                self._update_all_patients()
            except Exception as e:
                logger.error(f"VitalsSimulator error: {e}")
            time.sleep(self.update_interval)

    def _update_all_patients(self):
        """Update vitals for all patients and check for anomalies."""
        critical_count = 0

        for patient in self.registry.get_all():
            # Decide if this reading should contain an anomaly
            inject_anomaly = random.random() < self.anomaly_rate

            # Generate new vitals
            vitals = generate_vitals(ward=patient.ward, inject_anomaly=inject_anomaly)

            # Store vitals
            patient.current_vitals = vitals
            patient.vitals_history.append(vitals)

            # Update Prometheus metrics
            prom_metrics.patient_heart_rate.labels(
                patient_id=patient.patient_id,
                patient_name=patient.name,
                ward=patient.ward
            ).set(vitals["heart_rate"])

            prom_metrics.patient_spo2.labels(
                patient_id=patient.patient_id,
                ward=patient.ward
            ).set(vitals["spo2"])

            prom_metrics.patient_temperature.labels(
                patient_id=patient.patient_id,
                ward=patient.ward
            ).set(vitals["temperature"])

            prom_metrics.vitals_readings_total.labels(reading_type="automated").inc()

            # Check thresholds and generate alerts
            alerts = check_thresholds(
                patient.patient_id, patient.name, patient.ward, vitals
            )

            for alert in alerts:
                self.registry.add_alert(alert)
                prom_metrics.vitals_anomalies_total.labels(
                    anomaly_type=alert.alert_type,
                    severity=alert.severity,
                    ward=patient.ward
                ).inc()
                prom_metrics.alerts_generated_total.labels(
                    severity=alert.severity,
                    alert_type=alert.alert_type
                ).inc()
                logger.warning(f"Alert generated: {alert.message}")

            # Update patient status
            if any(a.severity == "CRITICAL" for a in alerts):
                patient.status = "critical"
                critical_count += 1
            elif any(a.severity == "WARNING" for a in alerts):
                patient.status = "warning"
            else:
                patient.status = "stable"

        # Update aggregate metrics
        prom_metrics.active_monitors.set(len(self.registry.patients))
        prom_metrics.critical_patients.set(critical_count)
        prom_metrics.monitored_wards.set(
            len(set(p.ward for p in self.registry.get_all()))
        )
