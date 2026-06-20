"""
NeuroSphere Robot Command Service — Main Flask Application

Provides a REST API for commanding autonomous surgical robots,
querying fleet status, and monitoring heartbeat telemetry.
Exposes Prometheus metrics, structured JSON logging, and
Kubernetes-style health/readiness probes.
"""

import logging
import json
import time
import random
import uuid
import sys
from datetime import datetime, timezone

from flask import Flask, request, jsonify, Response
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

from app.models import (
    FleetManager,
    RobotStatus,
    CommandType,
    ProcedureType,
    TYPE_TO_PROCEDURES,
)
from app.metrics import (
    robot_command_latency,
    robot_commands_total,
    robot_heartbeat_status,
    active_procedures_total,
    robot_battery_level,
    emergency_halts_total,
)


# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------

class JSONFormatter(logging.Formatter):
    """Emit structured JSON log lines with healthcare-relevant fields."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": "robot-command-service",
            "message": record.getMessage(),
            "logger": record.name,
        }
        if hasattr(record, "robot_id"):
            log_entry["robot_id"] = record.robot_id
        if hasattr(record, "command_type"):
            log_entry["command_type"] = record.command_type
        if record.exc_info and record.exc_info[1]:
            log_entry["exception"] = str(record.exc_info[1])
        return json.dumps(log_entry)


def _configure_logging():
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Application factory
# ---------------------------------------------------------------------------

def create_app() -> Flask:
    """Create and configure the Flask application."""

    _configure_logging()
    logger = logging.getLogger("robot-command-service")

    app = Flask(__name__)
    app.config["JSON_SORT_KEYS"] = False

    # Initialise the simulated robot fleet
    fleet = FleetManager()
    fleet.initialize_fleet()
    logger.info("Fleet initialised with %d robots", len(fleet.robots))

    # Seed Prometheus gauges with initial values
    for robot in fleet.get_all_robots():
        robot_heartbeat_status.labels(
            robot_id=robot.robot_id,
            robot_type=robot.type.value,
            hospital=robot.hospital,
        ).set(1)
        robot_battery_level.labels(
            robot_id=robot.robot_id,
            robot_type=robot.type.value,
        ).set(robot.battery_level)
    active_procedures_total.set(0)

    # ------------------------------------------------------------------
    # CORS — allow all origins for dev convenience
    # ------------------------------------------------------------------
    @app.after_request
    def _add_cors(response):
        response.headers["Access-Control-Allow-Origin"] = "*"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type,Authorization"
        response.headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS"
        return response

    # ------------------------------------------------------------------
    # POST /api/robots/command
    # ------------------------------------------------------------------
    @app.route("/api/robots/command", methods=["POST"])
    def send_command():
        """
        Send a command to an autonomous surgical robot.

        Expects JSON body:
          {
            "robot_id": "NSR-DA-VINCI-001",
            "command": "move | calibrate | start_procedure | stop_procedure | emergency_halt",
            "parameters": { ... }   // optional command-specific params
          }
        """
        body = request.get_json(silent=True)
        if not body:
            return jsonify({"error": "Request body must be valid JSON"}), 400

        robot_id = body.get("robot_id")
        command_str = body.get("command")
        params = body.get("parameters", {})

        # --- validation ---
        if not robot_id or not command_str:
            return jsonify({"error": "robot_id and command are required"}), 400

        try:
            command = CommandType(command_str)
        except ValueError:
            valid = [c.value for c in CommandType]
            return jsonify({"error": f"Invalid command. Must be one of {valid}"}), 400

        robot = fleet.get_robot(robot_id)
        if robot is None:
            return jsonify({"error": f"Robot '{robot_id}' not found in fleet"}), 404

        # --- simulate command execution latency (50–500 ms) ---
        latency = random.uniform(0.05, 0.5)
        time.sleep(latency)

        # Observe latency in Prometheus histogram
        robot_command_latency.labels(
            command_type=command.value,
            robot_type=robot.type.value,
        ).observe(latency)

        # --- execute command logic ---
        result_status = "success"
        detail = ""

        try:
            if command == CommandType.MOVE:
                if robot.status == RobotStatus.EMERGENCY_HALT:
                    raise RuntimeError("Robot is in EMERGENCY_HALT state — clear halt before issuing move")
                target = params.get("target_position", "home")
                robot.status = RobotStatus.ONLINE
                detail = f"Robot moving to position '{target}'"

            elif command == CommandType.CALIBRATE:
                if robot.status == RobotStatus.BUSY:
                    raise RuntimeError("Cannot calibrate while a procedure is active")
                robot.status = RobotStatus.CALIBRATING
                detail = "Calibration sequence initiated — estimated 90 s"

            elif command == CommandType.START_PROCEDURE:
                if robot.status == RobotStatus.BUSY:
                    raise RuntimeError(f"Robot already performing '{robot.current_procedure}'")
                if robot.status == RobotStatus.EMERGENCY_HALT:
                    raise RuntimeError("Robot is in EMERGENCY_HALT — cannot start procedure")
                available = TYPE_TO_PROCEDURES.get(robot.type, [])
                procedure_name = params.get("procedure")
                if procedure_name:
                    # Validate the requested procedure
                    try:
                        proc = ProcedureType(procedure_name)
                    except ValueError:
                        raise RuntimeError(f"Unknown procedure '{procedure_name}'")
                    if proc not in available:
                        raise RuntimeError(
                            f"Procedure '{procedure_name}' is not supported by robot type '{robot.type.value}'"
                        )
                else:
                    proc = random.choice(available) if available else None
                    procedure_name = proc.value if proc else "general_operation"

                robot.status = RobotStatus.BUSY
                robot.current_procedure = procedure_name
                robot.procedure_start_time = time.time()
                active_procedures_total.inc()
                detail = f"Procedure '{procedure_name}' started"

            elif command == CommandType.STOP_PROCEDURE:
                if robot.current_procedure is None:
                    raise RuntimeError("No active procedure to stop")
                stopped_proc = robot.current_procedure
                robot.status = RobotStatus.ONLINE
                robot.current_procedure = None
                robot.procedure_start_time = None
                robot.total_procedures_completed += 1
                active_procedures_total.dec()
                detail = f"Procedure '{stopped_proc}' stopped gracefully"

            elif command == CommandType.EMERGENCY_HALT:
                previous_status = robot.status.value
                if robot.current_procedure:
                    active_procedures_total.dec()
                robot.status = RobotStatus.EMERGENCY_HALT
                robot.current_procedure = None
                robot.procedure_start_time = None
                robot.error_count += 1
                emergency_halts_total.labels(robot_id=robot.robot_id).inc()
                detail = f"EMERGENCY HALT executed (previous state: {previous_status})"
                logger.warning(
                    "Emergency halt issued for %s at %s",
                    robot.robot_id,
                    robot.hospital,
                    extra={"robot_id": robot.robot_id, "command_type": "emergency_halt"},
                )

        except RuntimeError as exc:
            result_status = "rejected"
            detail = str(exc)

        robot_commands_total.labels(
            command_type=command.value,
            status=result_status,
        ).inc()

        # Drain a small amount of battery per command
        robot.battery_level = max(0.0, robot.battery_level - random.uniform(0.05, 0.3))
        robot_battery_level.labels(
            robot_id=robot.robot_id,
            robot_type=robot.type.value,
        ).set(robot.battery_level)

        logger.info(
            "Command '%s' -> %s  result=%s",
            command.value,
            robot.robot_id,
            result_status,
            extra={"robot_id": robot.robot_id, "command_type": command.value},
        )

        status_code = 200 if result_status == "success" else 409
        return jsonify({
            "command_id": str(uuid.uuid4()),
            "robot_id": robot.robot_id,
            "command": command.value,
            "status": result_status,
            "detail": detail,
            "latency_ms": round(latency * 1000, 1),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }), status_code

    # ------------------------------------------------------------------
    # GET /api/robots/status
    # ------------------------------------------------------------------
    @app.route("/api/robots/status", methods=["GET"])
    def fleet_status():
        """Return summary status of every robot in the fleet."""
        robots = [r.to_summary_dict() for r in fleet.get_all_robots()]
        return jsonify({
            "fleet_size": len(robots),
            "active_procedures": fleet.get_active_procedure_count(),
            "robots": robots,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        })

    # ------------------------------------------------------------------
    # GET /api/robots/heartbeat
    # ------------------------------------------------------------------
    @app.route("/api/robots/heartbeat", methods=["GET"])
    def heartbeat_check():
        """
        Simulate a heartbeat sweep across the fleet.

        Each robot has a 2 % chance of going offline on any given check.
        Offline robots can come back online on subsequent checks (10 % chance).
        """
        heartbeat_map = {}
        now = time.time()

        for robot in fleet.get_all_robots():
            if robot.status == RobotStatus.OFFLINE:
                # 10 % chance to recover
                if random.random() < 0.10:
                    robot.status = RobotStatus.ONLINE
                    robot.last_heartbeat = now
                    logger.info("Robot %s recovered (back online)", robot.robot_id)
            elif robot.status not in (RobotStatus.EMERGENCY_HALT, RobotStatus.MAINTENANCE):
                # 2 % chance to drop offline
                if random.random() < 0.02:
                    robot.status = RobotStatus.OFFLINE
                    robot.error_count += 1
                    logger.warning("Robot %s went OFFLINE (heartbeat lost)", robot.robot_id)
                else:
                    robot.last_heartbeat = now

            is_online = 1 if robot.status not in (RobotStatus.OFFLINE, RobotStatus.EMERGENCY_HALT) else 0
            heartbeat_map[robot.robot_id] = {
                "online": bool(is_online),
                "last_heartbeat": robot.last_heartbeat,
                "status": robot.status.value,
                "battery_level": round(robot.battery_level, 1),
            }

            robot_heartbeat_status.labels(
                robot_id=robot.robot_id,
                robot_type=robot.type.value,
                hospital=robot.hospital,
            ).set(is_online)

        return jsonify({
            "heartbeat": heartbeat_map,
            "checked_at": datetime.now(timezone.utc).isoformat(),
        })

    # ------------------------------------------------------------------
    # GET /api/robots/<robot_id>
    # ------------------------------------------------------------------
    @app.route("/api/robots/<robot_id>", methods=["GET"])
    def robot_detail(robot_id: str):
        """Return detailed status for a specific robot."""
        robot = fleet.get_robot(robot_id)
        if robot is None:
            return jsonify({"error": f"Robot '{robot_id}' not found"}), 404
        return jsonify(robot.to_dict())

    # ------------------------------------------------------------------
    # Health & Readiness probes
    # ------------------------------------------------------------------
    @app.route("/health", methods=["GET"])
    def health():
        """Kubernetes liveness probe — always returns 200 if the process is alive."""
        return jsonify({"status": "healthy", "service": "robot-command-service"})

    @app.route("/ready", methods=["GET"])
    def ready():
        """
        Kubernetes readiness probe — returns 200 only when the fleet
        is initialised and at least one robot is responsive.
        """
        if not fleet.robots:
            return jsonify({"status": "not_ready", "reason": "Fleet not initialised"}), 503

        online_count = sum(
            1 for r in fleet.robots.values()
            if r.status not in (RobotStatus.OFFLINE, RobotStatus.EMERGENCY_HALT)
        )
        if online_count == 0:
            return jsonify({"status": "not_ready", "reason": "No robots online"}), 503

        return jsonify({
            "status": "ready",
            "fleet_size": len(fleet.robots),
            "online_robots": online_count,
        })

    # ------------------------------------------------------------------
    # Prometheus /metrics
    # ------------------------------------------------------------------
    @app.route("/metrics", methods=["GET"])
    def metrics():
        """Expose Prometheus metrics."""
        return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

    return app


# Allow running directly with `python -m app.main`
if __name__ == "__main__":
    application = create_app()
    application.run(host="0.0.0.0", port=5000, debug=True)
