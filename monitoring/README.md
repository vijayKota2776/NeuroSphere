# NeuroSphere — Monitoring & Observability Stack

> Full-stack observability for the Global Autonomous Medical Robotics Operations Platform.
> HIPAA-ready logging, IEC 62443 device telemetry, and FDA SaMD diagnostic audit trails.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     NeuroSphere Monitoring Architecture                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────── METRICS LAYER ─────────────────────────────┐    │
│  │                                                                     │    │
│  │  ┌─────────────┐    scrape     ┌──────────────┐    query           │    │
│  │  │  Node        │──────────────▶│  Prometheus   │◀──────────┐      │    │
│  │  │  Exporter    │    :9100     │  :9090        │           │      │    │
│  │  │  (host)      │              └──────┬───────┘           │      │    │
│  │  └─────────────┘                      │                    │      │    │
│  │                                       │ alerts             │      │    │
│  │  ┌─────────────┐                     ▼                    │      │    │
│  │  │  Service     │ /metrics   ┌──────────────┐    ┌────────┴───┐  │    │
│  │  │  Endpoints   │───────────▶│ Alertmanager  │    │  Grafana    │  │    │
│  │  │  :5000-5050  │            │  :9093        │    │  :3001      │  │    │
│  │  └─────────────┘            └──────────────┘    └────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌──────────────────────── LOGGING LAYER (ELK) ───────────────────────┐    │
│  │                                                                     │    │
│  │  ┌─────────────┐  logs   ┌──────────────┐  json  ┌─────────────┐  │    │
│  │  │  Filebeat    │────────▶│  Logstash     │───────▶│Elasticsearch│  │    │
│  │  │  (shipper)   │  :5044 │  :5044/:5000  │  :9200│  :9200      │  │    │
│  │  └──────┬──────┘         │  :9600 (api)  │       └──────┬──────┘  │    │
│  │         │                └──────────────┘              │          │    │
│  │         │ Docker                                        │ query    │    │
│  │         │ socket                              ┌────────┴───┐      │    │
│  │         ▼                                     │  Kibana     │      │    │
│  │  ┌─────────────┐                             │  :5601      │      │    │
│  │  │  Container   │                             └────────────┘      │    │
│  │  │  Logs        │                                                  │    │
│  │  └─────────────┘                                                  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌──────────────────── NEUROSPHERE SERVICES ──────────────────────────┐    │
│  │  robot-command :5050  │  patient-monitor :5001  │  gateway :8080   │    │
│  │  diagnostic    :3000  │  telemetry       :5002  │                  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### Prerequisites

1. Docker Engine 24+ and Docker Compose v2
2. At least **6 GB RAM** available for Docker (Elasticsearch alone needs ~1.5 GB)
3. The main NeuroSphere network must exist:

```bash
# Create the network if not already present
docker network create neurosphere-network
```

### Launch

```bash
# Start the full monitoring stack
docker compose -f docker-compose.monitoring.yml up -d

# Verify all services are healthy
docker compose -f docker-compose.monitoring.yml ps

# Follow aggregated logs
docker compose -f docker-compose.monitoring.yml logs -f

# Stop and remove (preserves data volumes)
docker compose -f docker-compose.monitoring.yml down

# Stop and remove everything including data
docker compose -f docker-compose.monitoring.yml down -v
```

### Start with Main Services

```bash
# From project root — start both app services and monitoring
docker compose up -d && \
  docker compose -f monitoring/docker-compose.monitoring.yml up -d
```

---

## Access URLs

| Service        | URL                          | Credentials             | Purpose                         |
|----------------|------------------------------|--------------------------|----------------------------------|
| **Prometheus** | http://localhost:9090         | None                     | Metrics queries & alert rules   |
| **Grafana**    | http://localhost:3001         | `admin` / `neurosphere`  | Dashboards & visualization      |
| **Alertmanager** | http://localhost:9093       | None                     | Alert routing & silencing       |
| **Kibana**     | http://localhost:5601         | None (dev mode)          | Log exploration & dashboards    |
| **Elasticsearch** | http://localhost:9200     | None (dev mode)          | Search API & index management   |
| **Logstash API** | http://localhost:9600       | None                     | Pipeline stats & monitoring     |
| **Node Exporter** | http://localhost:9100/metrics | None                  | Host system metrics             |

---

## Alert Routing Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                     Alert Routing Pipeline                        │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Prometheus Alert Rules                                          │
│  ├── Critical (severity=critical)                                │
│  │   ├── Patient vitals out of range     → PagerDuty + Slack    │
│  │   ├── Robot safety interlock tripped  → PagerDuty + Slack    │
│  │   └── Service down > 2 min           → PagerDuty + Email    │
│  │                                                               │
│  ├── Warning (severity=warning)                                  │
│  │   ├── High error rate (> 5%)          → Slack #alerts        │
│  │   ├── Telemetry ingestion lag         → Slack #ops           │
│  │   └── Disk usage > 80%               → Slack #infra         │
│  │                                                               │
│  └── Info (severity=info)                                        │
│      ├── Diagnostic job completed        → Slack #diagnostics   │
│      └── Deployment events               → Slack #deployments   │
│                                                                  │
│  Silencing:                                                      │
│  ├── Maintenance windows via Alertmanager UI                     │
│  └── Auto-resolve after 5 min recovery                          │
│                                                                  │
│  Grouping:                                                       │
│  ├── By: cluster, service, severity                              │
│  ├── Group wait:    30s                                          │
│  ├── Group interval: 5m                                          │
│  └── Repeat interval: 4h                                        │
└──────────────────────────────────────────────────────────────────┘
```

---

## Dashboard Descriptions

### Grafana Dashboards

| Dashboard                     | Description                                                      |
|-------------------------------|------------------------------------------------------------------|
| **NeuroSphere Overview**      | High-level platform health: service status, request rates, error rates, uptime |
| **Robot Command Operations**  | Robot state machines, command latency distributions, safety interlock events, procedure timelines |
| **Patient Monitoring**        | Patient vital trends, ward occupancy, alert frequencies by severity, EHR integration status |
| **Diagnostic Pipeline**       | Scan processing queue depth, analysis throughput, model confidence distributions, SLA compliance |
| **Telemetry Ingestion**       | Ingest throughput (events/sec), batch processing latency, source distribution, data freshness |
| **API Gateway**               | Request rates by endpoint, response time percentiles, upstream health, rate limiting events |
| **Infrastructure**            | CPU/memory/disk/network utilization via Node Exporter, container resource usage |

### Kibana Dashboards

| Dashboard                     | Description                                                      |
|-------------------------------|------------------------------------------------------------------|
| **Service Logs Explorer**     | Full-text search across all NeuroSphere service logs             |
| **Error Analysis**            | Error log aggregation, stack traces, error rate trends           |
| **HIPAA Audit Trail**         | PHI access logs, patient data queries, compliance event timeline |
| **Robot Command Audit**       | Command history, safety events, latency analysis                 |
| **Diagnostic Audit Trail**    | FDA SaMD compliance: job tracking, model decisions, report generation |

---

## Elasticsearch Index Patterns

Logs are indexed per-service per-day for efficient querying and retention:

```
neurosphere-robot-command-YYYY.MM.dd
neurosphere-patient-monitor-YYYY.MM.dd
neurosphere-diagnostic-engine-YYYY.MM.dd
neurosphere-telemetry-ingest-YYYY.MM.dd
neurosphere-api-gateway-YYYY.MM.dd
neurosphere-unknown-YYYY.MM.dd
```

### Index Lifecycle Management (ILM)

| Phase    | Age     | Action                           |
|----------|---------|----------------------------------|
| Hot      | 0-7d    | Full indexing, 1 replica         |
| Warm     | 7-30d   | Read-only, force merge           |
| Cold     | 30-90d  | Frozen, searchable snapshot      |
| Delete   | 90d+    | Purge (adjust for HIPAA: 6 yrs) |

> **HIPAA Note**: Healthcare regulations may require log retention of 6+ years.
> Adjust the ILM delete phase accordingly in production.

---

## Logstash Pipeline

The Logstash pipeline (`elk/logstash/pipeline/neurosphere.conf`) provides:

- **3 Input Protocols**: Beats (5044), TCP/JSON (5000), HTTP webhook (8080)
- **11-Stage Filter Chain**:
  1. JSON parsing
  2. Environment metadata injection
  3. Service identification (from Docker labels / container names)
  4. Format-specific grok parsing (Nginx, Gunicorn, Winston)
  5. Service-specific field extraction (robot, patient, diagnostic, telemetry, gateway)
  6. ECS field normalization
  7. Timestamp parsing (multi-format)
  8. GeoIP enrichment (external IPs only)
  9. Healthcare compliance tagging (HIPAA, IEC 62443, FDA SaMD)
  10. SHA256 fingerprint deduplication
  11. Field cleanup
- **Elasticsearch Output**: Per-service index routing with ILM

---

## File Structure

```
monitoring/
├── docker-compose.monitoring.yml       # Full monitoring stack orchestration
├── README.md                           # This file
│
├── prometheus/
│   ├── prometheus.yml                  # Scrape config & alert rules reference
│   └── alert_rules.yml                 # Alert rule definitions
│
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/               # Auto-provisioned Prometheus datasource
│   │   └── dashboards/                # Dashboard provisioning config
│   └── dashboards/                     # JSON dashboard definitions
│
├── alertmanager/
│   └── alertmanager.yml                # Routing, receivers, inhibition rules
│
└── elk/
    ├── elasticsearch/
    │   └── elasticsearch.yml           # Cluster config (single-node dev mode)
    ├── logstash/
    │   ├── logstash.yml                # Logstash settings
    │   └── pipeline/
    │       └── neurosphere.conf        # Full processing pipeline
    ├── kibana/
    │   └── kibana.yml                  # Dashboard server config
    └── filebeat/
        └── filebeat.yml                # Docker log autodiscovery & shipping
```

---

## Healthcare Compliance Notes

### HIPAA (Patient Data)

- **PHI Tagging**: Logstash pipeline automatically tags events containing patient identifiers with `contains-phi` and `hipaa-regulated` tags
- **Audit Logging**: Enable `xpack.security.audit.enabled: true` in Elasticsearch for production
- **Encryption**: Configure TLS for Elasticsearch transport and HTTP layers
- **Access Control**: Enable `xpack.security.enabled: true` and configure RBAC
- **Retention**: Adjust ILM policy to retain logs for minimum 6 years

### IEC 62443 (Medical Device Security)

- **Device Logs**: Robot command logs tagged with `iec-62443-regulated`
- **Integrity**: Fingerprint deduplication ensures log integrity
- **Traceability**: Every robot command includes procedure ID, operator context

### FDA SaMD (Software as Medical Device)

- **Audit Trail**: Diagnostic pipeline events tagged with `fda-samd-audit`
- **Decision Logging**: Model confidence scores, scan types, processing times preserved
- **Immutability**: Elasticsearch indices can be set to read-only after warm phase

---

## Troubleshooting

### Elasticsearch won't start
```bash
# Check if vm.max_map_count is set (Linux only)
sysctl vm.max_map_count
# Should be at least 262144. If not:
sudo sysctl -w vm.max_map_count=262144

# Check container logs
docker logs neurosphere-elasticsearch
```

### Logstash not receiving logs
```bash
# Check Logstash pipeline stats
curl -s http://localhost:9600/_node/stats/pipelines | python3 -m json.tool

# Verify Filebeat is connected
docker logs neurosphere-filebeat | grep -i "connected"
```

### Kibana shows "No results found"
```bash
# Verify indices exist
curl -s http://localhost:9200/_cat/indices?v

# Create index pattern via API
curl -X POST http://localhost:5601/api/saved_objects/index-pattern \
  -H 'kbn-xsrf: true' \
  -H 'Content-Type: application/json' \
  -d '{"attributes":{"title":"neurosphere-*","timeFieldName":"@timestamp"}}'
```

### High memory usage
```bash
# Check Elasticsearch heap
curl -s http://localhost:9200/_nodes/stats/jvm | python3 -m json.tool | grep heap

# Reduce ES heap in docker-compose.monitoring.yml:
# ES_JAVA_OPTS=-Xms256m -Xmx256m  (minimum for dev)
```

---

## Resource Requirements

| Service         | CPU (limit) | Memory (limit) | Disk (est.)     |
|-----------------|-------------|----------------|-----------------|
| Prometheus      | 1.0 core    | 1 GB           | ~2 GB/month     |
| Grafana         | 0.5 core    | 512 MB         | ~100 MB         |
| Alertmanager    | 0.25 core   | 128 MB         | ~50 MB          |
| Node Exporter   | 0.25 core   | 128 MB         | N/A             |
| Elasticsearch   | 2.0 cores   | 1.5 GB         | ~5 GB/month     |
| Logstash        | 1.0 core    | 768 MB         | ~100 MB         |
| Kibana          | 1.0 core    | 1 GB           | ~200 MB         |
| Filebeat        | 0.5 core    | 256 MB         | ~50 MB          |
| **Total**       | **6.5 cores** | **~5.3 GB**  | **~8 GB/month** |

> **Minimum recommended**: 8 GB RAM allocated to Docker for running the full stack alongside NeuroSphere services.
