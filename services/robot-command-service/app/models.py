"""
Robot data models and simulation state for NeuroSphere Robot Command Service.

Defines the simulated surgical robot fleet, procedure types, and
command definitions used across the autonomous surgical robotics platform.
"""

import time
import random
import uuid
from dataclasses import dataclass, field
from typing import Dict, List, Optional
from enum import Enum


class RobotType(str, Enum):
    """Types of autonomous medical robots in the NeuroSphere fleet."""
    SURGICAL_ARM = "surgical_arm"
    DIAGNOSTIC_SCANNER = "diagnostic_scanner"
    REHABILITATION_BOT = "rehabilitation_bot"
    ENDOSCOPIC_NAVIGATOR = "endoscopic_navigator"
    MICROSURGERY_ASSISTANT = "microsurgery_assistant"


class RobotStatus(str, Enum):
    """Operational status of a robot."""
    ONLINE = "online"
    OFFLINE = "offline"
    BUSY = "busy"
    CALIBRATING = "calibrating"
    EMERGENCY_HALT = "emergency_halt"
    MAINTENANCE = "maintenance"


class CommandType(str, Enum):
    """Supported robot command types."""
    MOVE = "move"
    CALIBRATE = "calibrate"
    START_PROCEDURE = "start_procedure"
    STOP_PROCEDURE = "stop_procedure"
    EMERGENCY_HALT = "emergency_halt"


class ProcedureType(str, Enum):
    """Types of surgical/medical procedures robots can perform."""
    LAPAROSCOPIC_CHOLECYSTECTOMY = "laparoscopic_cholecystectomy"
    ROBOTIC_PROSTATECTOMY = "robotic_prostatectomy"
    CARDIAC_CATHETERIZATION = "cardiac_catheterization"
    SPINAL_FUSION = "spinal_fusion"
    CRANIOTOMY = "craniotomy"
    TOTAL_KNEE_ARTHROPLASTY = "total_knee_arthroplasty"
    ENDOSCOPIC_SINUS_SURGERY = "endoscopic_sinus_surgery"
    CT_GUIDED_BIOPSY = "ct_guided_biopsy"
    MRI_GUIDED_ABLATION = "mri_guided_ablation"
    PHYSICAL_THERAPY_SESSION = "physical_therapy_session"


# --- Fleet Configuration ---

ROBOT_DEFINITIONS = [
    {
        "robot_id": "NSR-DA-VINCI-001",
        "name": "Da Vinci Xi Alpha",
        "type": RobotType.SURGICAL_ARM,
        "hospital": "Massachusetts General Hospital",
        "department": "General Surgery - OR 7",
    },
    {
        "robot_id": "NSR-DA-VINCI-002",
        "name": "Da Vinci Xi Beta",
        "type": RobotType.SURGICAL_ARM,
        "hospital": "Mayo Clinic - Rochester",
        "department": "Cardiothoracic Surgery - OR 3",
    },
    {
        "robot_id": "NSR-MAKO-001",
        "name": "MAKO SmartRobotics Unit",
        "type": RobotType.SURGICAL_ARM,
        "hospital": "Johns Hopkins Hospital",
        "department": "Orthopedic Surgery - OR 12",
    },
    {
        "robot_id": "NSR-DIAG-001",
        "name": "NeuroScan Sentinel",
        "type": RobotType.DIAGNOSTIC_SCANNER,
        "hospital": "Cleveland Clinic",
        "department": "Radiology - Suite B",
    },
    {
        "robot_id": "NSR-DIAG-002",
        "name": "NeuroScan Guardian",
        "type": RobotType.DIAGNOSTIC_SCANNER,
        "hospital": "Stanford Medical Center",
        "department": "Interventional Radiology - IR 2",
    },
    {
        "robot_id": "NSR-REHAB-001",
        "name": "RehabAssist Exo-Pro",
        "type": RobotType.REHABILITATION_BOT,
        "hospital": "Shirley Ryan AbilityLab",
        "department": "Physical Therapy - Wing C",
    },
    {
        "robot_id": "NSR-REHAB-002",
        "name": "RehabAssist NeuroWalk",
        "type": RobotType.REHABILITATION_BOT,
        "hospital": "Kessler Institute for Rehabilitation",
        "department": "Neuro Rehab - Floor 3",
    },
    {
        "robot_id": "NSR-ENDO-001",
        "name": "EndoNav Precision",
        "type": RobotType.ENDOSCOPIC_NAVIGATOR,
        "hospital": "Mount Sinai Hospital",
        "department": "Gastroenterology - Endo Suite 1",
    },
    {
        "robot_id": "NSR-MICRO-001",
        "name": "MicroBot Neuro-X",
        "type": RobotType.MICROSURGERY_ASSISTANT,
        "hospital": "UCSF Medical Center",
        "department": "Neurosurgery - OR 5",
    },
    {
        "robot_id": "NSR-MICRO-002",
        "name": "MicroBot OptiSurge",
        "type": RobotType.MICROSURGERY_ASSISTANT,
        "hospital": "Hospital for Special Surgery",
        "department": "Microsurgery - OR 2",
    },
]

# Map robot types to the procedures they can perform
TYPE_TO_PROCEDURES = {
    RobotType.SURGICAL_ARM: [
        ProcedureType.LAPAROSCOPIC_CHOLECYSTECTOMY,
        ProcedureType.ROBOTIC_PROSTATECTOMY,
        ProcedureType.CARDIAC_CATHETERIZATION,
        ProcedureType.SPINAL_FUSION,
        ProcedureType.TOTAL_KNEE_ARTHROPLASTY,
    ],
    RobotType.DIAGNOSTIC_SCANNER: [
        ProcedureType.CT_GUIDED_BIOPSY,
        ProcedureType.MRI_GUIDED_ABLATION,
    ],
    RobotType.REHABILITATION_BOT: [
        ProcedureType.PHYSICAL_THERAPY_SESSION,
    ],
    RobotType.ENDOSCOPIC_NAVIGATOR: [
        ProcedureType.ENDOSCOPIC_SINUS_SURGERY,
    ],
    RobotType.MICROSURGERY_ASSISTANT: [
        ProcedureType.CRANIOTOMY,
        ProcedureType.SPINAL_FUSION,
    ],
}


@dataclass
class RobotState:
    """Runtime state of a single robot in the simulated fleet."""
    robot_id: str
    name: str
    type: RobotType
    hospital: str
    department: str
    status: RobotStatus = RobotStatus.ONLINE
    battery_level: float = 100.0
    last_heartbeat: float = field(default_factory=time.time)
    current_procedure: Optional[str] = None
    procedure_start_time: Optional[float] = None
    firmware_version: str = "4.7.2-neurosphere"
    uptime_seconds: float = 0.0
    total_procedures_completed: int = 0
    error_count: int = 0

    def to_dict(self) -> dict:
        """Serialize robot state to a JSON-friendly dictionary."""
        return {
            "robot_id": self.robot_id,
            "name": self.name,
            "type": self.type.value,
            "hospital": self.hospital,
            "department": self.department,
            "status": self.status.value,
            "battery_level": round(self.battery_level, 1),
            "last_heartbeat": self.last_heartbeat,
            "current_procedure": self.current_procedure,
            "procedure_start_time": self.procedure_start_time,
            "firmware_version": self.firmware_version,
            "uptime_seconds": round(self.uptime_seconds, 1),
            "total_procedures_completed": self.total_procedures_completed,
            "error_count": self.error_count,
        }

    def to_summary_dict(self) -> dict:
        """Compact summary for fleet-level status views."""
        return {
            "robot_id": self.robot_id,
            "name": self.name,
            "type": self.type.value,
            "status": self.status.value,
            "last_heartbeat": self.last_heartbeat,
            "current_procedure": self.current_procedure,
            "battery_level": round(self.battery_level, 1),
            "hospital": self.hospital,
            "department": self.department,
        }


class FleetManager:
    """
    Manages the simulated fleet of NeuroSphere surgical robots.

    Provides methods to initialize robots, send commands, check heartbeats,
    and query fleet status.  All state is held in-memory.
    """

    def __init__(self):
        self.robots: Dict[str, RobotState] = {}
        self._boot_time = time.time()

    def initialize_fleet(self):
        """Spin up the default fleet of 10 robots with randomised initial state."""
        for defn in ROBOT_DEFINITIONS:
            robot = RobotState(
                robot_id=defn["robot_id"],
                name=defn["name"],
                type=defn["type"],
                hospital=defn["hospital"],
                department=defn["department"],
                battery_level=round(random.uniform(65.0, 100.0), 1),
                last_heartbeat=time.time(),
                uptime_seconds=random.uniform(3600, 86400),
                total_procedures_completed=random.randint(0, 250),
            )
            self.robots[robot.robot_id] = robot

    def get_robot(self, robot_id: str) -> Optional[RobotState]:
        return self.robots.get(robot_id)

    def get_all_robots(self) -> List[RobotState]:
        return list(self.robots.values())

    def get_active_procedure_count(self) -> int:
        return sum(
            1 for r in self.robots.values()
            if r.current_procedure is not None and r.status == RobotStatus.BUSY
        )
