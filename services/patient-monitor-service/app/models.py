"""
Patient data models and in-memory state management.
Simulates a realistic patient monitoring system with ward assignments,
medical conditions, and vitals history tracking.
"""

import uuid
import time
from datetime import datetime
from collections import deque


class Patient:
    """Represents a monitored patient with vitals history."""

    def __init__(self, name, age, ward, condition, assigned_robot_id=None):
        self.patient_id = str(uuid.uuid4())[:8]
        self.name = name
        self.age = age
        self.ward = ward
        self.condition = condition
        self.assigned_robot_id = assigned_robot_id
        self.status = "stable"
        self.admitted_at = datetime.utcnow().isoformat() + "Z"
        self.current_vitals = {}
        self.vitals_history = deque(maxlen=100)  # Keep last 100 readings
        self.alerts = []

    def to_dict(self):
        return {
            "patient_id": self.patient_id,
            "name": self.name,
            "age": self.age,
            "ward": self.ward,
            "condition": self.condition,
            "assigned_robot_id": self.assigned_robot_id,
            "status": self.status,
            "admitted_at": self.admitted_at,
            "current_vitals": self.current_vitals,
        }

    def to_detail_dict(self):
        data = self.to_dict()
        data["vitals_history"] = list(self.vitals_history)[-20:]  # Last 20
        data["active_alerts"] = [a for a in self.alerts if not a.get("acknowledged")]
        return data


class Alert:
    """Represents a patient monitoring alert."""

    def __init__(self, patient_id, severity, alert_type, message, vital_name=None, vital_value=None):
        self.alert_id = str(uuid.uuid4())[:8]
        self.patient_id = patient_id
        self.severity = severity  # INFO, WARNING, CRITICAL
        self.alert_type = alert_type
        self.message = message
        self.vital_name = vital_name
        self.vital_value = vital_value
        self.timestamp = datetime.utcnow().isoformat() + "Z"
        self.acknowledged = False
        self.acknowledged_at = None
        self.created_epoch = time.time()

    def to_dict(self):
        return {
            "alert_id": self.alert_id,
            "patient_id": self.patient_id,
            "severity": self.severity,
            "alert_type": self.alert_type,
            "message": self.message,
            "vital_name": self.vital_name,
            "vital_value": self.vital_value,
            "timestamp": self.timestamp,
            "acknowledged": self.acknowledged,
            "acknowledged_at": self.acknowledged_at,
        }


class PatientRegistry:
    """In-memory registry of all monitored patients."""

    def __init__(self):
        self.patients = {}
        self.alerts = deque(maxlen=500)
        self.alerts_today_count = 0

    def register(self, patient):
        self.patients[patient.patient_id] = patient
        return patient

    def get(self, patient_id):
        return self.patients.get(patient_id)

    def get_all(self):
        return list(self.patients.values())

    def add_alert(self, alert):
        self.alerts.appendleft(alert)
        self.alerts_today_count += 1
        patient = self.patients.get(alert.patient_id)
        if patient:
            patient.alerts.append(alert.to_dict())
            # Keep only last 20 alerts per patient
            if len(patient.alerts) > 20:
                patient.alerts = patient.alerts[-20:]

    def get_active_alerts(self):
        return [a.to_dict() for a in self.alerts if not a.acknowledged]

    def get_dashboard_summary(self):
        total = len(self.patients)
        critical = sum(1 for p in self.patients.values() if p.status == "critical")
        warning = sum(1 for p in self.patients.values() if p.status == "warning")
        stable = sum(1 for p in self.patients.values() if p.status == "stable")
        wards = set(p.ward for p in self.patients.values())
        active_alerts = len([a for a in self.alerts if not a.acknowledged])

        return {
            "total_patients": total,
            "critical_count": critical,
            "warning_count": warning,
            "stable_count": stable,
            "wards_monitored": list(wards),
            "active_alerts": active_alerts,
            "alerts_today": self.alerts_today_count,
        }


# ──────────────────────────────────────────────
# Default patients to initialize on startup
# ──────────────────────────────────────────────

DEFAULT_PATIENTS = [
    {"name": "Eleanor Mitchell", "age": 72, "ward": "ICU", "condition": "Post-cardiac surgery recovery", "assigned_robot_id": "ROBO-SA-001"},
    {"name": "James Thornton", "age": 58, "ward": "Cardiac", "condition": "Atrial fibrillation monitoring", "assigned_robot_id": "ROBO-PM-003"},
    {"name": "Priya Sharma", "age": 34, "ward": "Surgical", "condition": "Post-appendectomy observation", "assigned_robot_id": "ROBO-SA-002"},
    {"name": "Robert Chen", "age": 67, "ward": "ICU", "condition": "Sepsis recovery - mechanical ventilation", "assigned_robot_id": "ROBO-PM-001"},
    {"name": "Maria Garcia", "age": 45, "ward": "Oncology", "condition": "Post-chemotherapy monitoring", "assigned_robot_id": None},
    {"name": "William Park", "age": 81, "ward": "General", "condition": "Pneumonia - oxygen therapy", "assigned_robot_id": "ROBO-PM-005"},
    {"name": "Aisha Okonkwo", "age": 29, "ward": "Surgical", "condition": "Post-laparoscopic cholecystectomy", "assigned_robot_id": "ROBO-SA-004"},
    {"name": "David Nakamura", "age": 55, "ward": "Cardiac", "condition": "Acute myocardial infarction - stent placement recovery", "assigned_robot_id": "ROBO-SA-003"},
    {"name": "Sophie Laurent", "age": 42, "ward": "General", "condition": "Type 2 diabetes - insulin adjustment", "assigned_robot_id": None},
    {"name": "Marcus Johnson", "age": 8, "ward": "Pediatric", "condition": "Tonsillectomy recovery", "assigned_robot_id": "ROBO-SA-005"},
    {"name": "Fatima Al-Hassan", "age": 63, "ward": "ICU", "condition": "Traumatic brain injury - ICP monitoring", "assigned_robot_id": "ROBO-PM-002"},
    {"name": "Thomas Eriksson", "age": 76, "ward": "Oncology", "condition": "Stage III lung cancer - post-lobectomy", "assigned_robot_id": "ROBO-SA-006"},
    {"name": "Yuki Tanaka", "age": 38, "ward": "Surgical", "condition": "Robotic-assisted prostatectomy recovery", "assigned_robot_id": "ROBO-SA-007"},
    {"name": "Catherine O'Brien", "age": 85, "ward": "General", "condition": "Hip replacement rehabilitation", "assigned_robot_id": "ROBO-RH-001"},
    {"name": "Ahmad Patel", "age": 51, "ward": "Cardiac", "condition": "Congestive heart failure - diuretic therapy", "assigned_robot_id": "ROBO-PM-004"},
]
