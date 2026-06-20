"""
Prometheus metrics definitions for Patient Monitor Service.
Exposes healthcare-specific metrics for patient vitals monitoring.
"""

from prometheus_client import Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST

# ──────────────────────────────────────────────
# Patient Vitals Metrics
# ──────────────────────────────────────────────

vitals_anomalies_total = Counter(
    'patient_vitals_anomalies_total',
    'Total number of vitals anomalies detected',
    ['anomaly_type', 'severity', 'ward']
)

alert_response_time = Histogram(
    'patient_alert_response_time_seconds',
    'Time taken to acknowledge patient alerts',
    ['severity'],
    buckets=[0.5, 1, 2, 5, 10, 30, 60, 120, 300]
)

active_monitors = Gauge(
    'active_patient_monitors',
    'Number of patients currently being monitored'
)

critical_patients = Gauge(
    'critical_patients_count',
    'Number of patients in critical condition'
)

patient_heart_rate = Gauge(
    'patient_heart_rate',
    'Current heart rate for each patient',
    ['patient_id', 'patient_name', 'ward']
)

patient_spo2 = Gauge(
    'patient_spo2_level',
    'Current SpO2 level for each patient',
    ['patient_id', 'ward']
)

patient_temperature = Gauge(
    'patient_temperature_celsius',
    'Current temperature for each patient',
    ['patient_id', 'ward']
)

vitals_readings_total = Counter(
    'vitals_readings_total',
    'Total number of vitals readings taken',
    ['reading_type']
)

alerts_generated_total = Counter(
    'patient_alerts_generated_total',
    'Total alerts generated',
    ['severity', 'alert_type']
)

monitored_wards = Gauge(
    'monitored_wards_total',
    'Number of wards with active monitoring'
)


def get_metrics():
    """Generate current Prometheus metrics."""
    return generate_latest(), CONTENT_TYPE_LATEST
