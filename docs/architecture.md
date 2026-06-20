# NeuroSphere — Architecture Guide

> Detailed system architecture for the Global Autonomous Medical Robotics Platform

---

## Table of Contents

1. [System Context](#1-system-context)
2. [Service-Level Design](#2-service-level-design)
3. [Network Topology](#3-network-topology)
4. [Data Flow Diagrams](#4-data-flow-diagrams)
5. [Security Architecture](#5-security-architecture)
6. [Monitoring Architecture](#6-monitoring-architecture)
7. [CI/CD Pipeline Architecture](#7-cicd-pipeline-architecture)
8. [Disaster Recovery Architecture](#8-disaster-recovery-architecture)
9. [Live EC2 Deployment](#9-live-ec2-deployment)

---

## 1. System Context

NeuroSphere operates as the central nervous system for autonomous surgical robotics deployments across multiple hospital systems. The platform sits between clinical operators (surgeons, clinicians, biomedical engineers) and the physical robot hardware, providing a unified control plane for commanding robots, monitoring patients, analyzing diagnostics, and ingesting sensor telemetry.

### External Systems & Actors

```
    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
    │   Surgeon    │    │  Clinician   │    │  Biomed Eng  │    │   DevOps     │
    │   Console    │    │  Dashboard   │    │  Terminal    │    │   Engineer   │
    └──────┬───────┘    └──────┬───────┘    └──────┬───────┘    └──────┬───────┘
           │                   │                   │                   │
           │   HTTPS/WSS       │   HTTPS           │   SSH/HTTPS      │  CI/CD
           │                   │                   │                   │
    ┌──────▼───────────────────▼───────────────────▼───────────────────▼───────┐
    │                                                                          │
    │                     NEUROSPHERE PLATFORM                                 │
    │                                                                          │
    │  ┌─────────────────────────────────────────────────────────────────────┐  │
    │  │                     API Gateway (Nginx)                            │  │
    │  │         Rate Limiting · CORS · Audit Logging · Tracing            │  │
    │  └───────────────────────────┬─────────────────────────────────────┘  │
    │                              │                                        │
    │  ┌───────────┐ ┌────────────┐ ┌──────────────┐ ┌──────────────────┐  │
    │  │  Robot    │ │ Diagnostic │ │   Patient    │ │    Telemetry     │  │
    │  │  Command  │ │  Engine    │ │   Monitor    │ │    Ingest        │  │
    │  │  Service  │ │  Service   │ │   Service    │ │    Service       │  │
    │  └─────┬─────┘ └─────┬──────┘ └──────┬───────┘ └───────┬──────────┘  │
    │        │              │               │                 │             │
    └────────┼──────────────┼───────────────┼─────────────────┼─────────────┘
             │              │               │                 │
    ┌────────▼──┐   ┌───────▼───┐   ┌──────▼──────┐   ┌──────▼──────┐
    │ Surgical  │   │   PACS    │   │    EHR      │   │   IoT       │
    │  Robots   │   │  Systems  │   │   Systems   │   │  Sensors    │
    │ (Da Vinci │   │ (DICOM)   │   │  (HL7/FHIR) │   │ (MQTT)      │
    │  ROSA,etc)│   │           │   │             │   │             │
    └───────────┘   └───────────┘   └─────────────┘   └─────────────┘
```

### Interaction Summary

| External System | Protocol | Direction | Purpose |
|----------------|----------|-----------|---------|
| Surgeon Console | HTTPS/WSS | Bidirectional | Real-time robot control commands |
| Clinician Dashboard | HTTPS | Read-heavy | Patient vitals, alerts, diagnostics |
| PACS Systems | DICOM/HTTPS | Inbound | Diagnostic imaging (CT, MRI, X-ray) |
| EHR Systems | HL7 FHIR/HTTPS | Bidirectional | Patient demographics, vitals integration |
| IoT Sensors | MQTT/HTTPS | Inbound | Robot telemetry, environmental sensors |
| CI/CD Pipeline | HTTPS | Deployment | Automated build, test, deploy |

---

## 2. Service-Level Design

### 2.1 Robot Command Service

**Purpose:** Real-time command and control interface for autonomous surgical robot fleets.

| Attribute | Value |
|-----------|-------|
| **Language** | Python 3.12 / Flask |
| **Port** | 5000 (mapped to 5050 externally) |
| **Compliance** | IEC 62443 |
| **Resource Limits** | 0.50 CPU, 256 MB memory |

**Data Model:**
```
FleetManager
  └── robots: Dict[str, Robot]
        ├── robot_id: str         (e.g., "NSR-DA-VINCI-001")
        ├── type: RobotType       (da_vinci, rosa, mako, ion, monarch)
        ├── status: RobotStatus   (online, offline, busy, calibrating, maintenance, emergency_halt)
        ├── hospital: str         (assigned hospital name)
        ├── battery_level: float  (0.0–100.0)
        ├── current_procedure: Optional[str]
        ├── procedure_start_time: Optional[float]
        ├── total_procedures_completed: int
        ├── error_count: int
        └── last_heartbeat: float
```

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/robots/command` | Send command (move, calibrate, start/stop procedure, emergency halt) |
| `GET` | `/api/robots/status` | Fleet summary with all robots |
| `GET` | `/api/robots/heartbeat` | Heartbeat sweep with offline detection (2% failure, 10% recovery) |
| `GET` | `/api/robots/<robot_id>` | Detailed robot status |

**Prometheus Metrics:**
- `robot_commands_total{command_type, status}` — Counter
- `robot_command_latency_seconds{command_type, robot_type}` — Histogram
- `robot_heartbeat_status{robot_id, robot_type, hospital}` — Gauge
- `robot_battery_level{robot_id, robot_type}` — Gauge
- `active_procedures_total` — Gauge
- `emergency_halts_total{robot_id}` — Counter

---

### 2.2 Diagnostic Engine Service

**Purpose:** AI-powered diagnostic imaging analysis with queued processing pipeline.

| Attribute | Value |
|-----------|-------|
| **Language** | Node.js 20 / Express |
| **Port** | 3000 |
| **Compliance** | FDA SaMD (Software as a Medical Device) |
| **Resource Limits** | 1.00 CPU, 512 MB memory |

**Data Model:**
```
DiagnosticJob
  ├── job_id: string (UUID)
  ├── patient_id: string
  ├── scan_type: string        (ct_scan, mri, xray, ultrasound, pet_scan, mammogram)
  ├── body_region: string      (head, chest, abdomen, spine, pelvis, extremities)
  ├── priority: string         (stat, urgent, routine)
  ├── status: string           (pending → processing → completed | failed)
  ├── created_at: ISO timestamp
  ├── started_at: ISO timestamp
  ├── completed_at: ISO timestamp
  ├── estimated_seconds: number
  └── result: DiagnosticResult
        ├── findings: string[]
        ├── confidence_score: number (0.0–1.0)
        ├── result_category: string (normal, abnormal, critical, inconclusive)
        ├── recommendations: string[]
        ├── processing_time_s: number
        └── model_version: string
```

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/diagnostics/analyze` | Submit diagnostic scan for AI analysis |
| `GET` | `/api/diagnostics/queue` | Queue status dashboard |
| `GET` | `/api/diagnostics/results/:jobId` | Results for a specific job |
| `GET` | `/api/diagnostics/stats` | Aggregate statistics |

**Prometheus Metrics:**
- `diagnostic_scans_total{scan_type, result}` — Counter
- `diagnostic_analysis_duration_seconds{scan_type}` — Histogram
- `diagnostic_queue_depth{priority}` — Gauge
- `diagnostic_accuracy_rate` — Gauge
- `diagnostic_throughput_per_minute` — Gauge

---

### 2.3 Patient Monitor Service

**Purpose:** Continuous real-time patient vitals monitoring with anomaly detection and alerting.

| Attribute | Value |
|-----------|-------|
| **Language** | Python 3.12 / Flask |
| **Port** | 5001 |
| **Compliance** | HIPAA |
| **Resource Limits** | 0.50 CPU, 256 MB memory |

**Data Model:**
```
Patient
  ├── patient_id: str (auto-generated, e.g., "PAT-001")
  ├── name: str
  ├── age: int
  ├── ward: str                (surgical_icu, neuro_icu, cardiac_icu, post_op, operating_room)
  ├── condition: str           (post_craniotomy, spinal_fusion, etc.)
  ├── assigned_robot_id: Optional[str]
  ├── status: str              (stable, warning, critical)
  ├── current_vitals: dict
  │     ├── heart_rate: float        (bpm, normal: 60–100)
  │     ├── blood_pressure_systolic: float (mmHg, normal: 90–140)
  │     ├── blood_pressure_diastolic: float (mmHg, normal: 60–90)
  │     ├── spo2: float              (%, normal: 95–100)
  │     ├── temperature: float       (°C, normal: 36.1–37.8)
  │     ├── respiratory_rate: float  (breaths/min, normal: 12–20)
  │     └── intracranial_pressure: Optional[float] (mmHg)
  ├── vitals_history: deque    (circular buffer of readings)
  └── active_alerts: list
```

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/patients/vitals` | Current vitals for all patients |
| `GET` | `/api/patients/vitals/<id>` | Detailed vitals with history |
| `GET` | `/api/patients/alerts` | Active alerts (filterable by severity) |
| `GET` | `/api/patients/dashboard` | Monitoring overview dashboard |
| `POST` | `/api/patients/register` | Register a new patient |
| `GET` | `/api/patients/history/<id>` | Historical vitals readings |

**Prometheus Metrics:**
- `patient_vitals_readings_total` — Counter
- `critical_alerts_total{severity}` — Counter
- `active_monitors` — Gauge
- `patient_heart_rate{patient_id}` — Gauge
- `patient_spo2{patient_id}` — Gauge

---

### 2.4 Telemetry Ingest Service

**Purpose:** High-throughput telemetry pipeline for robot sensors, environmental monitors, and edge devices.

| Attribute | Value |
|-----------|-------|
| **Language** | Python 3.12 / Flask |
| **Port** | 5002 |
| **Compliance** | IEC 62443 |
| **Resource Limits** | 0.75 CPU, 384 MB memory |

**Data Model:**
```
TelemetryEvent
  ├── event_id: str (UUID, auto-generated)
  ├── source_id: str           (e.g., "NSR-DA-VINCI-001", "ENV-SENSOR-OR3")
  ├── source_type: str         (surgical_robot, patient_monitor, env_sensor, gateway)
  ├── event_type: str          (heartbeat, position_update, error, vital_sign, calibration)
  ├── timestamp: str (ISO 8601)
  └── payload: dict            (event-specific data)

CircularBuffer
  ├── _capacity: int = 10,000
  ├── _buffer: deque
  ├── total_events: int
  ├── error_count: int
  ├── events_by_type: Counter
  └── events_by_source_type: Counter
```

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/telemetry/ingest` | Ingest single or array of events |
| `POST` | `/api/telemetry/ingest/batch` | Batch ingestion (up to 1,000 events) |
| `GET` | `/api/telemetry/stats` | Real-time pipeline stats |
| `GET` | `/api/telemetry/recent` | Recent events (filterable) |
| `GET` | `/api/telemetry/errors` | Recent error events |
| `GET` | `/api/telemetry/health-summary` | Source health aggregation |

**Prometheus Metrics:**
- `telemetry_events_total{source_type, event_type}` — Counter
- `telemetry_ingest_latency_seconds` — Histogram
- `telemetry_buffer_size` — Gauge
- `telemetry_events_per_second` — Gauge
- `telemetry_errors_total` — Counter
- `telemetry_sources_active` — Gauge

---

### 2.5 API Gateway (Nginx)

**Purpose:** Unified entry point for all client traffic with security, observability, and traffic management.

| Attribute | Value |
|-----------|-------|
| **Technology** | Nginx |
| **Port** | 80 (mapped to 8080 externally) |
| **Resource Limits** | 0.25 CPU, 128 MB memory |

**Features:**
- Rate limiting: 10 req/s per client IP (shared memory zone: 10 MB ≈ 160K IPs)
- CORS headers with preflight handling
- JSON-structured audit logging (HIPAA compliance)
- X-Request-ID propagation for distributed tracing
- Custom healthcare-appropriate error pages (429, 502, 503, 504)
- Security headers (X-Content-Type-Options, X-Frame-Options, X-XSS-Protection)
- Upstream keepalive connection pooling (16 connections per upstream)
- Server version hiding (`server_tokens off`)

**Routing Table:**

| Location | Upstream | Timeout (Read) | Burst |
|----------|----------|-----------------|-------|
| `/api/robots/` | `robot-command-service:5000` | 30s | 20 |
| `/api/diagnostics/` | `diagnostic-engine-service:3000` | 60s | 20 |
| `/api/patients/` | `patient-monitor-service:5001` | 30s | 20 |
| `/api/telemetry/` | `telemetry-ingest-service:5002` | 15s | 40 |
| `/health` | Direct (gateway self) | — | — |

---

## 3. Network Topology

### AWS VPC Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AWS VPC (10.0.0.0/16)                             │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │                    Availability Zone A                                  │ │
│  │                                                                        │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐           │ │
│  │  │ Public Subnet  │  │ Private Subnet │  │ Database Subnet│           │ │
│  │  │ 10.0.1.0/24    │  │ 10.0.10.0/24   │  │ 10.0.20.0/24   │           │ │
│  │  │                │  │                │  │                │           │ │
│  │  │ ┌────────────┐ │  │ ┌────────────┐ │  │ ┌────────────┐ │           │ │
│  │  │ │ NAT GW     │ │  │ │ EKS Nodes  │ │  │ │ (Reserved) │ │           │ │
│  │  │ │ ALB        │ │  │ │ Vault Pods │ │  │ │            │ │           │ │
│  │  │ └────────────┘ │  │ └────────────┘ │  │ └────────────┘ │           │ │
│  │  └────────────────┘  └────────────────┘  └────────────────┘           │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │                    Availability Zone B                                  │ │
│  │                                                                        │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐           │ │
│  │  │ Public Subnet  │  │ Private Subnet │  │ Database Subnet│           │ │
│  │  │ 10.0.2.0/24    │  │ 10.0.11.0/24   │  │ 10.0.21.0/24   │           │ │
│  │  │                │  │                │  │                │           │ │
│  │  │ ┌────────────┐ │  │ ┌────────────┐ │  │ ┌────────────┐ │           │ │
│  │  │ │ NAT GW     │ │  │ │ EKS Nodes  │ │  │ │ (Reserved) │ │           │ │
│  │  │ │ (HA mode)  │ │  │ │            │ │  │ │            │ │           │ │
│  │  │ └────────────┘ │  │ └────────────┘ │  │ └────────────┘ │           │ │
│  │  └────────────────┘  └────────────────┘  └────────────────┘           │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐  │
│  │   IGW    │ │   WAF    │ │   KMS    │ │   ECR    │ │   CloudWatch     │  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────────────┘  │
│                                                                             │
│  VPC Flow Logs → CloudWatch (HIPAA audit trail)                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Security Groups

| Security Group | Inbound | Outbound | Attached To |
|---------------|---------|----------|-------------|
| `sg-alb` | 80/443 from 0.0.0.0/0 | All to `sg-eks-nodes` | Application Load Balancer |
| `sg-eks-nodes` | All from `sg-alb`, All from `sg-eks-nodes` | All outbound | EKS worker nodes |
| `sg-vault` | 8200 from `sg-eks-nodes` | All outbound | Vault instances |
| `sg-database` | 5432 from `sg-eks-nodes` | None | Database subnet (reserved) |

### Kubernetes Network Policies

```yaml
# Default: deny all ingress/egress in neurosphere namespace
kind: NetworkPolicy → default-deny-all

# Allow: services can communicate with each other within namespace
kind: NetworkPolicy → allow-neurosphere-internal

# Allow: Prometheus can scrape /metrics from all services
kind: NetworkPolicy → allow-prometheus-scrape

# Allow: services can reach Vault on port 8200
kind: NetworkPolicy → allow-vault-access
```

---

## 4. Data Flow Diagrams

### 4.1 Surgical Command Lifecycle

```
Surgeon Console                                     NeuroSphere Platform
      │
      │  POST /api/robots/command
      │  {"robot_id": "NSR-DA-VINCI-001",
      │   "command": "start_procedure",
      │   "parameters": {"procedure": "laparoscopic_cholecystectomy"}}
      │
      ▼
┌──────────┐     ┌─────────────┐     ┌───────────────────────┐
│  Nginx   │────▶│   Robot     │────▶│  Validate Command     │
│  Gateway │     │  Command    │     │  • Robot exists?       │
│          │     │  Service    │     │  • Status allows cmd?  │
│ ✓ Rate   │     │  (:5000)    │     │  • Procedure supported?│
│   limit  │     │             │     └──────────┬────────────┘
│ ✓ Audit  │     │             │                │
│   log    │     │             │     ┌──────────▼────────────┐
│ ✓ Trace  │     │             │     │  Execute Command      │
│   ID     │     │             │     │  • Update robot state  │
└──────────┘     │             │     │  • Simulate latency    │
                 │             │     │  • Drain battery       │
                 │             │◄────│  • Inc Prometheus ctr  │
                 │             │     └──────────┬────────────┘
                 │             │                │
                 │             │     ┌──────────▼────────────┐
                 │             │────▶│  Response             │
                 │             │     │  command_id, status,   │
                 │             │     │  detail, latency_ms    │
                 └─────────────┘     └───────────────────────┘
                        │
                        ▼  (async)
                 ┌─────────────┐
                 │  Telemetry  │  Receives command telemetry
                 │  Ingest     │  for audit & analytics
                 │  (:5002)    │
                 └─────────────┘
```

### 4.2 Patient Monitoring Flow

```
                    ┌──────────────────────────┐
                    │   VitalsSimulator        │
                    │   (Background Thread)    │
                    │                          │
                    │  Every 3s per patient:   │
                    │  • Generate vitals       │
                    │  • Check thresholds      │
                    │  • 5% anomaly injection  │
                    │  • Update Prometheus     │
                    └────────────┬─────────────┘
                                │ writes
                                ▼
                    ┌──────────────────────────┐
                    │   PatientRegistry        │
                    │                          │
                    │  ┌─── Patient 1 ───────┐ │
                    │  │ vitals: {HR, SpO2,..}│ │
                    │  │ history: deque[100]  │ │
                    │  │ alerts: [...]        │ │
                    │  └─────────────────────┘ │
                    │  ┌─── Patient 2 ───────┐ │
                    │  │ ...                  │ │
                    │  └─────────────────────┘ │
                    └────────────┬─────────────┘
                                │ reads
                                ▼
  Clinician ──GET──▶ /api/patients/dashboard ──▶ Summary JSON
  Clinician ──GET──▶ /api/patients/alerts    ──▶ Active alerts
  Clinician ──GET──▶ /api/patients/vitals    ──▶ All patient vitals
                                │
                                ▼
                    ┌──────────────────────────┐
                    │   Alert Thresholds       │
                    │                          │
                    │  HR < 40 or HR > 180     │  → CRITICAL
                    │  SpO2 < 88              │  → CRITICAL
                    │  HR < 50 or HR > 150     │  → WARNING
                    │  SpO2 < 92              │  → WARNING
                    │  Temp < 35.5 or > 38.5  │  → WARNING
                    └──────────────────────────┘
```

### 4.3 Diagnostic Pipeline

```
Clinician                                  Diagnostic Engine Service
    │
    │  POST /api/diagnostics/analyze
    │  {"patient_id": "PAT-003",
    │   "scan_type": "ct_scan",
    │   "body_region": "chest",
    │   "priority": "stat"}
    │
    ▼
┌───────────────┐    ┌──────────────────────────────────────────────────┐
│   Validate    │───▶│         Job Queue (In-Memory)                    │
│   • patient_id│    │                                                  │
│   • scan_type │    │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐           │
│   • body_region    │  │ STAT │ │ URG  │ │ ROUT │ │ ROUT │  ...      │
│   • priority  │    │  │ Job1 │ │ Job2 │ │ Job3 │ │ Job4 │           │
│               │    │  └──┬───┘ └──────┘ └──────┘ └──────┘           │
│ → 202 Accepted│    │     │                                           │
└───────────────┘    │     ▼                                           │
                     │  ┌──────────────────────────────────┐           │
                     │  │  Background Processing Loop      │           │
                     │  │  (2–8 second simulated GPU time)  │           │
                     │  │                                   │           │
                     │  │  1. Dequeue next job              │           │
                     │  │  2. generateDiagnosticResult()    │           │
                     │  │     • findings[]                  │           │
                     │  │     • confidence_score (0.0–1.0)  │           │
                     │  │     • result_category             │           │
                     │  │     • recommendations[]           │           │
                     │  │  3. Record Prometheus metrics     │           │
                     │  │  4. Schedule next iteration       │           │
                     │  └──────────────────────────────────┘           │
                     └──────────────────────────────────────────────────┘
                                        │
                                        ▼
                     GET /api/diagnostics/results/:jobId → Completed result
```

---

## 5. Security Architecture

### Defense-in-Depth Layers

```
Layer 1: Edge Security
┌─────────────────────────────────────────────────────────────────┐
│  AWS WAF → CloudFront → ALB                                     │
│  • IP reputation filtering                                      │
│  • Rate limiting (global)                                       │
│  • SQL injection / XSS rules                                    │
│  • Geo-blocking (US hospitals only)                             │
└─────────────────────────────────────────────────────────────────┘
                              │
Layer 2: Application Gateway
┌─────────────────────────────────────────────────────────────────┐
│  Nginx API Gateway                                              │
│  • Rate limiting (10 req/s per IP)                              │
│  • CORS enforcement                                             │
│  • Security headers (HSTS, CSP, X-Frame-Options)               │
│  • JSON audit logging for compliance                            │
│  • X-Request-ID tracing                                         │
└─────────────────────────────────────────────────────────────────┘
                              │
Layer 3: Network Security
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Network Policies                                    │
│  • Default deny all ingress/egress                             │
│  • Explicit allow-list between services                         │
│  • Prometheus scrape allowed on /metrics only                   │
│  • Vault access restricted to service accounts                  │
│  VPC Security Groups                                            │
│  • Strict port-based access between tiers                       │
└─────────────────────────────────────────────────────────────────┘
                              │
Layer 4: Application Security
┌─────────────────────────────────────────────────────────────────┐
│  Service-Level Controls                                         │
│  • Input validation on all endpoints                            │
│  • Structured error handling (no stack trace leaks)             │
│  • Request body size limits (16 MiB)                           │
│  • Prometheus metrics (no PII in labels)                        │
│  Security Scanning                                              │
│  • Trivy: Container image vulnerability scanning                │
│  • Bandit: Python static security analysis                      │
│  • OWASP Dependency Check: Library vulnerability scanning       │
└─────────────────────────────────────────────────────────────────┘
                              │
Layer 5: Secrets Management
┌─────────────────────────────────────────────────────────────────┐
│  HashiCorp Vault                                                │
│  • Per-service policies (least-privilege)                       │
│  • Kubernetes auth backend (IRSA)                               │
│  • Auto-unseal with AWS KMS                                     │
│  • Secret rotation support                                      │
│  • Audit logging of all secret access                           │
│                                                                 │
│  Policies:                                                      │
│  ├── neurosphere-admin          (full access)                   │
│  ├── neurosphere-services       (read service secrets)          │
│  ├── neurosphere-cicd           (read/write deploy secrets)     │
│  ├── neurosphere-robot-command  (read robot-specific secrets)   │
│  └── neurosphere-patient-monitor (read patient-specific secrets)│
└─────────────────────────────────────────────────────────────────┘
                              │
Layer 6: Data Encryption
┌─────────────────────────────────────────────────────────────────┐
│  Encryption at Rest                                             │
│  • AWS KMS for EBS volumes, S3 buckets, ECR images             │
│  • Vault auto-unseal key (KMS)                                 │
│  Encryption in Transit                                          │
│  • TLS 1.2+ at ALB/Ingress                                    │
│  • Internal service mesh mTLS (future: Istio/Linkerd)          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. Monitoring Architecture

### Metrics Pipeline

```
┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│ Robot Command │     │  Patient      │     │  Diagnostic   │
│ /metrics      │     │  Monitor      │     │  Engine       │
│ :5000         │     │  /metrics     │     │  /metrics     │
│               │     │  :5001        │     │  :3000        │
└───────┬───────┘     └───────┬───────┘     └───────┬───────┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              │ scrape every 15s
                              ▼
                    ┌───────────────────┐
                    │    Prometheus     │
                    │    :9090          │
                    │                   │
                    │ • Scrape configs  │
                    │ • Recording rules │
                    │ • Alert rules     │
                    │ • 15d retention   │
                    └────────┬──────────┘
                             │
                ┌────────────┼────────────┐
                ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────────┐
        │ Grafana  │ │Alertmgr │ │ Recording    │
        │ :3001    │ │ :9093   │ │ Rules        │
        │          │ │          │ │              │
        │ 4 dashb: │ │ Routes:  │ │ Pre-compute: │
        │ • Robot  │ │ • Slack  │ │ • Rates      │
        │ • Patient│ │ • Email  │ │ • Aggregates │
        │ • Service│ │ • PagerD │ │ • Quantiles  │
        │ • System │ │          │ │              │
        └──────────┘ └──────────┘ └──────────────┘
```

### Logging Pipeline

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Robot Cmd    │  │ Patient Mon  │  │ Diagnostic   │  │ Telemetry    │
│ JSON logs    │  │ JSON logs    │  │ JSON logs    │  │ JSON logs    │
│ → stdout     │  │ → stdout     │  │ → stdout     │  │ → stdout     │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │                 │
       └─────────────────┼─────────────────┼─────────────────┘
                         │ Docker log driver / Filebeat
                         ▼
               ┌───────────────────┐
               │    Filebeat       │
               │    (Shipper)      │
               │                   │
               │ • Collect logs    │
               │ • Parse JSON      │
               │ • Add metadata    │
               └─────────┬─────────┘
                         │
                         ▼
               ┌───────────────────┐
               │    Logstash       │
               │    (Pipeline)     │
               │                   │
               │ • Filter/enrich   │
               │ • GeoIP lookup    │
               │ • PII masking     │
               │ • Index routing   │
               └─────────┬─────────┘
                         │
                         ▼
               ┌───────────────────┐
               │  Elasticsearch    │
               │  (Storage)        │
               │                   │
               │ • Index lifecycle  │
               │ • 30-day retention│
               │ • Sharding        │
               └─────────┬─────────┘
                         │
                         ▼
               ┌───────────────────┐
               │    Kibana         │
               │    (UI)           │
               │                   │
               │ • Log search      │
               │ • Dashboards      │
               │ • Alerting        │
               └───────────────────┘
```

---

## 7. CI/CD Pipeline Architecture

### Pipeline Flow

```
┌─────────┐    ┌──────────────────────────────────────────────────────────────┐
│  Git    │    │                    Jenkins Pipeline                          │
│  Push   │───▶│                                                              │
│         │    │  Stage 1: Checkout                                           │
│ (GitHub │    │  └── Clone repository, detect changed services               │
│  webhook)    │                                                              │
└─────────┘    │  Stage 2: Quality Gate                                       │
               │  ├── Python: flake8 + black --check + bandit                 │
               │  ├── Node.js: npm run lint + npm audit                       │
               │  └── Fail pipeline if violations exceed threshold            │
               │                                                              │
               │  Stage 3: Unit Tests                                         │
               │  ├── Python: pytest --cov (min 80% coverage)                 │
               │  ├── Node.js: jest --coverage (min 80% coverage)             │
               │  └── Publish test reports to Jenkins                         │
               │                                                              │
               │  Stage 4: Security Scan                                      │
               │  ├── Trivy: container image vulnerability scan               │
               │  ├── Bandit: Python security static analysis                 │
               │  ├── OWASP DC: dependency vulnerability check                │
               │  └── Fail on CRITICAL/HIGH vulnerabilities                   │
               │                                                              │
               │  Stage 5: Docker Build                                       │
               │  ├── Multi-stage build (builder → production)                │
               │  ├── Tag: ECR_REPO:GIT_SHA + latest                         │
               │  ├── Push to AWS ECR                                         │
               │  └── Trivy scan on final image                               │
               │                                                              │
               │  Stage 6: Deploy (per environment)                           │
               │  ├── Dev: auto-deploy on main branch                         │
               │  ├── Staging: auto-deploy, run integration tests             │
               │  ├── Prod: manual approval gate, canary deploy              │
               │  └── kustomize build | kubectl apply                        │
               │                                                              │
               │  Stage 7: Notify                                             │
               │  ├── Slack notification (success/failure)                    │
               │  └── Update deployment dashboard                             │
               └──────────────────────────────────────────────────────────────┘
```

### Shared Library Functions

| Function | Purpose |
|----------|---------|
| `neurospherePipeline()` | Main pipeline template with standardised stages |
| `dockerBuild()` | Multi-stage Docker build + ECR push |
| `kubernetesDeploy()` | Kustomize-based K8s deployment |
| `securityScan()` | Trivy + Bandit + OWASP scan orchestration |
| `qualityGate()` | Lint, test coverage, quality threshold checks |
| `notifySlack()` | Slack webhook notification formatting |

---

## 8. Disaster Recovery Architecture

### RTO/RPO Targets

| Component | RTO (Recovery Time) | RPO (Recovery Point) | Strategy |
|-----------|--------------------|-----------------------|----------|
| Application Services | < 5 minutes | 0 (stateless) | K8s auto-restart, multi-replica |
| Vault Secrets | < 15 minutes | < 1 hour | Automated backup (CronJob every 6h) |
| Kubernetes State | < 30 minutes | < 6 hours | etcd snapshots, cluster rebuild |
| Monitoring Data | < 1 hour | < 24 hours | Prometheus snapshot restore |
| ELK Logs | < 2 hours | < 24 hours | Elasticsearch snapshot/restore |

### Backup Strategy

```
┌──────────────────────────────────────────────────────────────────┐
│                    Automated Backup Schedule                      │
│                                                                  │
│  ┌─────────────────┐  Every 6 hours                              │
│  │ K8s CronJob     │──────────────────────────────┐              │
│  │ backup-cronjob  │                              │              │
│  └─────────────────┘                              │              │
│                                                   ▼              │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ backup-etcd.sh  │  │ backup-vault.sh │  │ backup-dbs.sh   │  │
│  │ • etcd snapshot  │  │ • Vault snapshot│  │ • pg_dump       │  │
│  │ • Encrypt (KMS)  │  │ • Encrypt (KMS) │  │ • Encrypt (KMS) │  │
│  │ • Upload S3     │  │ • Upload S3     │  │ • Upload S3     │  │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘  │
│                              │                                   │
│                              ▼                                   │
│                    ┌─────────────────┐                           │
│                    │ S3 Bucket       │                           │
│                    │ (Versioned)     │                           │
│                    │ 90-day lifecycle│                           │
│                    └─────────────────┘                           │
└──────────────────────────────────────────────────────────────────┘
```

### Chaos Engineering Experiments

| Experiment | Type | Validates |
|------------|------|-----------|
| Pod Failure | Application | Service auto-recovery, PDB enforcement |
| Network Latency | Network | Timeout handling, circuit breakers |
| Network Partition | Network | Service isolation resilience |
| DNS Failure | Network | DNS caching, fallback behavior |
| CPU Stress | Resource | HPA scaling, resource limits |
| Memory Stress | Resource | OOM handling, memory limits |
| Node Drain | Infrastructure | Pod rescheduling, PDB compliance |

### Failover Procedure

```
1. Detect failure (Alertmanager → PagerDuty)
2. Assess scope (single service vs. node vs. AZ)
3. Execute appropriate runbook:
   ├── Service failure  → K8s auto-restarts (built-in)
   ├── Node failure     → K8s reschedules pods to healthy nodes
   ├── AZ failure       → Traffic shifts to surviving AZ
   └── Region failure   → DR failover script (manual trigger)
4. Verify recovery (health checks, Prometheus alerts clear)
5. Post-incident review
```

---

*For operational procedures, see [Operations Runbook](runbook.md).*
*For deployment instructions, see [Deployment Guide](deployment-guide.md).*
*For detailed API documentation, see [API Reference](api-reference.md).*

---

## 9. Live EC2 Deployment

NeuroSphere is currently deployed and running on AWS EC2:

### Instance Details

| Attribute | Value |
|-----------|-------|
| **Instance Name** | `neurosphere-server` |
| **Instance ID** | `i-0b838d997334670f2` |
| **Instance Type** | `t3.small` |
| **Region** | `ap-south-1` (Mumbai) |
| **OS** | Amazon Linux 2023 |
| **Public IP** | `13.126.102.15` |
| **Containers Running** | 9 |

### Live Service URLs

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     LIVE EC2 DEPLOYMENT (13.126.102.15)                     │
├──────────────────────────────────────┬─────────────────────────────────────────┤
│ Service                              │ URL                                     │
├──────────────────────────────────────┼─────────────────────────────────────────┤
│ Dashboard                            │ http://13.126.102.15:3333               │
│ Grafana (admin/neurosphere)          │ http://13.126.102.15:3001               │
│ Jenkins CI/CD                        │ http://13.126.102.15:8081               │
│ Prometheus                           │ http://13.126.102.15:9090               │
│ Robot Command API                    │ http://13.126.102.15:5050               │
│ Patient Monitor API                  │ http://13.126.102.15:5001               │
│ Diagnostic Engine API                │ http://13.126.102.15:3000               │
│ Telemetry Ingest API                 │ http://13.126.102.15:5002               │
│ API Gateway                          │ http://13.126.102.15:8080               │
└──────────────────────────────────────┴─────────────────────────────────────────┘
```

### Architecture with EC2 IP

```
  Internet
     │
     ▼
┌─────────────────────────────────────────────────────┐
│          EC2: 13.126.102.15 (t3.small)              │
│          neurosphere-server                          │
│          ap-south-1 (Mumbai)                         │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │           Docker Compose (9 containers)        │  │
│  │                                                │  │
│  │  :3333  ── Dashboard                           │  │
│  │  :8080  ── Nginx Gateway ──┐                   │  │
│  │  :5050  ── Robot Command   │  Core             │  │
│  │  :5001  ── Patient Monitor │  Services         │  │
│  │  :3000  ── Diagnostic Eng  │                   │  │
│  │  :5002  ── Telemetry Ingest┘                   │  │
│  │  :9090  ── Prometheus      ┐  Monitoring       │  │
│  │  :3001  ── Grafana         ┘  Stack            │  │
│  │  :8081  ── Jenkins CI/CD                       │  │
│  └────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```
