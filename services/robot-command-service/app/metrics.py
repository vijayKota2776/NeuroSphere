"""
Prometheus metrics definitions for the NeuroSphere Robot Command Service.

All custom healthcare-specific metrics are defined here and imported
by the main application.
"""

from prometheus_client import Counter, Gauge, Histogram

# --- Histograms ---

robot_command_latency = Histogram(
    "robot_command_latency_seconds",
    "Latency of robot command execution in seconds",
    labelnames=["command_type", "robot_type"],
    buckets=(0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0),
)

# --- Counters ---

robot_commands_total = Counter(
    "robot_commands_total",
    "Total number of robot commands issued",
    labelnames=["command_type", "status"],
)

emergency_halts_total = Counter(
    "emergency_halts_total",
    "Total number of emergency halt commands issued",
    labelnames=["robot_id"],
)

# --- Gauges ---

robot_heartbeat_status = Gauge(
    "robot_heartbeat_status",
    "Heartbeat status of each robot (1=online, 0=offline)",
    labelnames=["robot_id", "robot_type", "hospital"],
)

active_procedures_total = Gauge(
    "active_procedures_total",
    "Number of currently active surgical/medical procedures",
)

robot_battery_level = Gauge(
    "robot_battery_level",
    "Current battery level percentage per robot",
    labelnames=["robot_id", "robot_type"],
)
