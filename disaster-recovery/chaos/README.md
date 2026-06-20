# 🔥 NeuroSphere Chaos Engineering Framework

> **Building confidence in the resilience of medical robotics infrastructure through controlled failure injection.**

## Table of Contents

- [Why Chaos Engineering for Healthcare?](#why-chaos-engineering-for-healthcare)
- [Architecture Overview](#architecture-overview)
- [Experiment Catalog](#experiment-catalog)
- [Safety Controls](#safety-controls)
- [How to Run Experiments](#how-to-run-experiments)
- [Interpreting Results](#interpreting-results)
- [Scheduled Testing Calendar](#scheduled-testing-calendar)
- [Emergency Procedures](#emergency-procedures)
- [Compliance & Regulatory](#compliance--regulatory)

---

## Why Chaos Engineering for Healthcare?

Medical robotics systems like NeuroSphere operate under **zero-tolerance failure requirements**. Unlike typical web applications where brief downtime means lost revenue, failures in surgical robotics can compromise **patient safety**.

### The Paradox

The more critical a system is, the more important it is to test its failure modes — but also the more dangerous those tests become. Our chaos engineering framework resolves this paradox through:

1. **Graduated risk levels** — Start with low-risk experiments, build confidence, then escalate
2. **Healthcare-specific safety gates** — Active surgical procedures always block chaos testing
3. **Blast radius control** — Every experiment has a defined, limited impact scope
4. **Steady-state validation** — Automated health checks before and after every experiment
5. **Emergency abort** — One-command termination of all chaos experiments

### What We're Validating

| Resilience Property | Why It Matters | How We Test |
|---|---|---|
| **Self-healing** | Pods must restart after failure | Pod termination |
| **Latency tolerance** | Surgical control loops need <50ms | Network delay injection |
| **Secret caching** | Vault outage can't block operations | Network partition |
| **Auto-scaling** | Diagnostic load spikes during emergencies | CPU stress |
| **Memory resilience** | Telemetry can't lose patient data | Memory pressure |
| **Node tolerance** | Hardware failures happen | Node drain |
| **DNS resilience** | Service discovery must be robust | DNS failure |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Chaos Mesh Operator                       │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Experiments  │  │  Workflows   │  │  Safety Controls  │  │
│  │             │  │              │  │                   │  │
│  │ pod-failure │  │ steady-state │  │ safety-rules.yaml │  │
│  │ net-latency │  │ full-suite   │  │ abort-all.sh      │  │
│  │ net-partition│  │              │  │ admission webhook │  │
│  │ cpu-stress  │  │              │  │ RBAC policies     │  │
│  │ mem-stress  │  │              │  │                   │  │
│  │ node-drain  │  │              │  │                   │  │
│  │ dns-failure │  │              │  │                   │  │
│  └──────┬──────┘  └──────┬───────┘  └─────────┬─────────┘  │
│         │                │                     │            │
│         └────────────────┼─────────────────────┘            │
│                          │                                  │
│                    ┌─────▼─────┐                            │
│                    │ Scheduler │                            │
│                    └─────┬─────┘                            │
└──────────────────────────┼──────────────────────────────────┘
                           │
              ┌────────────▼────────────┐
              │   neurosphere-core      │
              │                         │
              │  ┌─────────────────┐    │
              │  │ patient-monitor  │    │
              │  │ robot-command    │    │
              │  │ diagnostic-eng.  │    │
              │  │ telemetry-ingest │    │
              │  │ api-gateway      │    │
              │  └─────────────────┘    │
              └─────────────────────────┘
```

---

## Experiment Catalog

### Risk Rating Scale

| Rating | Color | Description | Approval Required |
|--------|-------|-------------|-------------------|
| 🟢 **LOW** | Green | Minimal blast radius, no patient impact possible | Self-service |
| 🟡 **MEDIUM** | Yellow | Limited blast radius, indirect patient impact possible | Team lead |
| 🔴 **HIGH** | Red | Broad blast radius, patient systems potentially affected | SRE lead + Clinical lead |

### Experiments

#### 1. Pod Failure — `experiments/pod-failure.yaml`

| Property | Value |
|---|---|
| **Risk Level** | 🟡 MEDIUM |
| **Target** | Random pod in `neurosphere-core` |
| **Action** | Kill one pod |
| **Duration** | 30 seconds (pod restart time) |
| **Schedule** | Every 30 minutes |
| **Blast Radius** | Single pod |
| **Expected Recovery** | Pod rescheduled within 30s |
| **Key Metric** | `kube_pod_status_ready` |

**What we learn:** Validates Kubernetes self-healing, ReplicaSet controllers, and PodDisruptionBudget enforcement.

---

#### 2. Network Latency — `experiments/network-latency.yaml`

| Property | Value |
|---|---|
| **Risk Level** | 🔴 HIGH |
| **Target** | `robot-command-service` |
| **Action** | Inject 200ms latency ± 50ms jitter |
| **Duration** | 5 minutes |
| **Blast Radius** | Robot command network path |
| **Abort Condition** | Active procedures > 0 |
| **Expected Recovery** | Immediate upon experiment end |
| **Key Metric** | `neurosphere_robot_command_latency_seconds` |

**What we learn:** Whether the surgical control loop degrades gracefully under network stress and correctly engages safety interlocks at high latency.

> ⚠️ **NEVER run during active surgical procedures.** The abort condition automatically terminates this experiment if a procedure is detected.

---

#### 3. Network Partition — `experiments/network-partition.yaml`

| Property | Value |
|---|---|
| **Risk Level** | 🔴 HIGH |
| **Target** | `neurosphere-core` ↔ `neurosphere-vault` |
| **Action** | Full bidirectional network partition |
| **Duration** | 2 minutes |
| **Blast Radius** | Cross-namespace (Vault access) |
| **Expected Behavior** | Services use cached secrets |
| **Expected Recovery** | Vault re-sync within 60s of partition end |
| **Key Metric** | `vault_agent_cache_hit_rate` |

**What we learn:** Whether Vault Agent sidecar caching provides sufficient resilience during Vault unavailability. Cache TTL (15 min) is well beyond the 2-minute partition.

---

#### 4. CPU Stress — `experiments/cpu-stress.yaml`

| Property | Value |
|---|---|
| **Risk Level** | 🟡 MEDIUM |
| **Target** | `diagnostic-engine` pods |
| **Action** | 80% CPU load |
| **Duration** | 5 minutes |
| **Blast Radius** | Diagnostic processing performance |
| **Expected Behavior** | HPA scales from 2 → 4+ replicas |
| **Expected Recovery** | Scale-down after 5-10 min cooldown |
| **Key Metric** | `kube_horizontalpodautoscaler_status_desired_replicas` |

**What we learn:** Whether HPA correctly detects CPU pressure and scales the diagnostic engine to maintain processing time SLOs for medical image analysis.

---

#### 5. Memory Stress — `experiments/memory-stress.yaml`

| Property | Value |
|---|---|
| **Risk Level** | 🔴 HIGH |
| **Target** | `telemetry-ingest` pods |
| **Action** | Fill to 90% of memory limit |
| **Duration** | 3 minutes |
| **Blast Radius** | Telemetry data pipeline |
| **Expected Behavior** | Graceful degradation or OOMKill + restart |
| **Expected Recovery** | Pod restart within 10s, Kafka preserves data |
| **Key Metric** | `container_memory_working_set_bytes` |

**What we learn:** Whether the telemetry pipeline handles memory pressure gracefully and whether Kafka buffering prevents data loss during OOMKill events.

---

#### 6. Node Drain — `experiments/node-drain.yaml`

| Property | Value |
|---|---|
| **Risk Level** | 🔴 HIGH |
| **Target** | Random worker node |
| **Action** | Cordon + drain (PDB-respecting) |
| **Duration** | 10 minutes |
| **Blast Radius** | All pods on one node |
| **Expected Behavior** | PDBs enforce minAvailable, pods reschedule |
| **Expected Recovery** | All pods running on other nodes within 5 min |
| **Key Metric** | `kube_pod_status_phase` |

**What we learn:** Whether PodDisruptionBudgets correctly prevent simultaneous eviction and whether pod anti-affinity rules enable proper rescheduling.

---

#### 7. DNS Failure — `experiments/dns-failure.yaml`

| Property | Value |
|---|---|
| **Risk Level** | 🔴 HIGH |
| **Target** | CoreDNS / cluster DNS |
| **Action** | DNS resolution failure for cluster domains |
| **Duration** | 1 minute |
| **Blast Radius** | Cluster-wide DNS resolution |
| **Expected Behavior** | Cached DNS entries used, persistent connections maintained |
| **Expected Recovery** | Immediate upon DNS restoration |
| **Key Metric** | `coredns_dns_request_duration_seconds` |

**What we learn:** Whether NodeLocal DNS Cache and persistent connections provide sufficient resilience during brief DNS outages.

---

## Safety Controls

### The 7 Safety Rules

Every chaos experiment in this framework is governed by these non-negotiable safety rules:

```
┌──────────────────────────────────────────────────────────────┐
│                    SAFETY RULES                              │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  SR-001  NEVER target patient-monitor during active alerts   │
│  SR-002  NEVER run chaos during active surgical procedures   │
│  SR-003  Maximum 1 experiment at a time                      │
│  SR-004  Auto-abort if any P0 service goes down              │
│  SR-005  Require manual approval for production chaos        │
│  SR-006  Block chaos during maintenance windows              │
│  SR-007  Maximum experiment duration: 10 minutes             │
│                                                              │
│  HEALTHCARE-SPECIFIC:                                        │
│  SR-H01  No chaos during peak clinical hours (7AM-7PM)       │
│  SR-H02  Protected services list (patient-monitor, robot-cmd)│
│  SR-H03  Exempt pod labels honored (chaos-exempt=true)       │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Enforcement Layers

1. **RBAC** — Only `neurosphere-sre-team` members can create chaos experiments
2. **Admission Webhook** — Validates every experiment against safety rules before admission
3. **Label Selectors** — Pods with `neurosphere.io/chaos-exempt=true` are never targeted
4. **StatusCheck Resources** — Continuous monitoring aborts experiments if safety conditions change
5. **Emergency Abort** — `abort-all.sh` provides one-command termination

### Emergency Abort

If anything goes wrong during chaos testing:

```bash
# From any machine with kubectl access:
./safety/abort-all.sh --reason "Unexpected patient system impact"

# What it does:
# 1. Kills ALL running chaos experiments (all types, all namespaces)
# 2. Removes all chaos schedules and workflows
# 3. Restores network policies to defaults
# 4. Restarts pods in unhealthy states
# 5. Uncordons any cordoned nodes
# 6. Sends Slack + PagerDuty alerts
# 7. Logs incident for post-mortem
```

**Rule of thumb:** When in doubt, abort. The script is safe to run at any time and only affects chaos resources.

---

## How to Run Experiments

### Prerequisites

1. **Chaos Mesh installed** in the cluster ([installation guide](https://chaos-mesh.org/docs/quick-start/))
2. **RBAC configured** — Your user must be in `neurosphere-sre-team` group
3. **Safety webhook deployed** — Admission webhook must be active
4. **No active procedures** — Check: `kubectl exec -it <robot-command-pod> -- curl localhost:8080/api/v1/procedures/active`

### Running a Single Experiment

```bash
# 1. Verify safety pre-conditions
kubectl get pods -n neurosphere-core -l project=neurosphere

# 2. Apply the experiment
kubectl apply -f experiments/pod-failure.yaml

# 3. Monitor experiment status
kubectl get podchaos -n neurosphere-core -w

# 4. Check service health during experiment
watch -n 5 'kubectl get pods -n neurosphere-core'

# 5. Review results
kubectl describe podchaos neurosphere-pod-failure -n neurosphere-core
```

### Running the Full Chaos Suite

```bash
# 1. Notify the team
# Post in #neurosphere-chaos: "Starting full chaos suite run"

# 2. Apply the workflow
kubectl apply -f workflows/full-chaos-suite.yaml

# 3. Monitor workflow progress
kubectl get workflow neurosphere-full-chaos-suite -n neurosphere-core -w

# 4. View workflow details
kubectl describe workflow neurosphere-full-chaos-suite -n neurosphere-core

# 5. Emergency abort (if needed)
./safety/abort-all.sh --reason "Description of issue"
```

### Running Steady-State Validation Only

```bash
# Useful for verifying system health without running chaos
kubectl apply -f workflows/steady-state-validation.yaml
kubectl get workflow neurosphere-steady-state -n neurosphere-core -w
```

---

## Interpreting Results

### Success Criteria

An experiment is considered **successful** if:

| Criterion | Description |
|---|---|
| ✅ Steady state restored | Post-experiment health checks all pass |
| ✅ Recovery within SLO | Service recovered faster than SLO target |
| ✅ No data loss | Patient/telemetry data integrity maintained |
| ✅ Alerts fired correctly | Expected alerts triggered within threshold |
| ✅ No cascade failures | Failure was contained to the blast radius |

### Failure Analysis

If an experiment reveals a weakness:

1. **Document the finding** — Create a JIRA ticket with experiment ID and observations
2. **Classify severity** — Use the patient safety impact scale:
   - **P0**: Direct patient safety impact → Immediate fix required
   - **P1**: Potential patient safety impact → Fix within 1 sprint
   - **P2**: Operational resilience gap → Fix within 1 quarter
   - **P3**: Nice-to-have improvement → Backlog
3. **Fix and re-test** — Apply the fix, then re-run the specific experiment
4. **Update steady-state** — Add new health checks if the failure revealed monitoring gaps

### Key Dashboards

| Dashboard | URL | Purpose |
|---|---|---|
| Chaos Overview | `grafana/d/chaos-overview` | Real-time experiment status |
| Service Health | `grafana/d/neurosphere-health` | Service health during chaos |
| HPA Activity | `grafana/d/hpa-scaling` | Auto-scaling behavior |
| Network Metrics | `grafana/d/network-chaos` | Latency and partition impact |

---

## Scheduled Testing Calendar

### Quarterly Chaos Testing Schedule

| Quarter | Date | Type | Experiments | Duration |
|---------|------|------|-------------|----------|
| Q1 | January 20 | Full Suite | All 7 experiments | ~2 hours |
| Q2 | April 21 | Full Suite | All 7 experiments | ~2 hours |
| Q3 | July 21 | Full Suite | All 7 experiments | ~2 hours |
| Q4 | October 20 | Full Suite + GameDay | All + custom scenarios | ~4 hours |

### Weekly Automated Tests (Non-Production)

| Day | Time (UTC) | Experiment | Environment |
|-----|------------|------------|-------------|
| Monday | 02:00 | Pod Failure | staging |
| Tuesday | 02:00 | Network Latency | staging |
| Wednesday | 02:00 | CPU Stress | staging |
| Thursday | 02:00 | Memory Stress | staging |
| Friday | 02:00 | DNS Failure | staging |

### Monthly Production Tests

| Week | Experiment | Approval Required |
|------|------------|-------------------|
| 1st Monday | Pod Failure (targeted, non-critical only) | Team lead |
| 2nd Monday | Network Latency (reduced: 100ms, 2 min) | SRE lead |
| 3rd Monday | CPU Stress (reduced: 60%, 3 min) | SRE lead |
| 4th Monday | Steady-State Validation only | Self-service |

### Blocked Windows

- **Sundays 02:00–06:00 UTC** — Weekly maintenance
- **1st of month 00:00–06:00 UTC** — Monthly patching
- **Quarterly DR test days** — Conflict with DR testing
- **Peak clinical hours** — Mon–Fri 07:00–19:00 ET, Sat 07:00–13:00 ET

---

## Emergency Procedures

### If a Chaos Experiment Causes Patient System Impact

```
1. IMMEDIATELY run:  ./safety/abort-all.sh --reason "Patient system impact"
2. Verify patient-monitor is healthy:
   kubectl get pods -n neurosphere-core -l app=patient-monitor
3. Verify robot-command is healthy:
   kubectl get pods -n neurosphere-core -l app=robot-command-service
4. Notify clinical engineering lead
5. Create P0 incident in JIRA
6. Conduct post-mortem within 24 hours
```

### If the Abort Script Fails

```
1. Manual cleanup — delete chaos resources directly:
   kubectl delete podchaos,networkchaos,stresschaos,dnschaos --all -n neurosphere-core
2. Manual pod restart:
   kubectl rollout restart deployment -n neurosphere-core -l project=neurosphere
3. Manual node uncordon:
   kubectl uncordon <node-name>
4. Contact: platform-reliability@neurosphere.io
```

---

## Compliance & Regulatory

This chaos engineering framework is designed to comply with:

| Regulation | Relevance |
|---|---|
| **FDA 21 CFR Part 820** | Quality System Regulation for medical devices |
| **IEC 62304** | Medical device software lifecycle |
| **IEC 80601-2-77** | Robotically assisted surgical equipment |
| **HIPAA** | Patient data protection during chaos testing |
| **SOC 2 Type II** | Operational resilience evidence |

All chaos experiments are logged, auditable, and traceable. Experiment results contribute to the continuous validation evidence required by regulatory bodies.

---

## Contributing

### Adding a New Experiment

1. Create the experiment YAML in `experiments/`
2. Add healthcare-specific labels and annotations
3. Define abort conditions for patient-safety scenarios
4. Add the experiment to the risk catalog (this README)
5. Get approval from SRE lead and clinical engineering
6. Test in staging environment first
7. Add to the `full-chaos-suite.yaml` workflow if appropriate

### Contact

| Role | Contact | Responsibility |
|---|---|---|
| SRE Lead | platform-reliability@neurosphere.io | Chaos framework ownership |
| Clinical Engineering | clinical-eng@neurosphere.io | Patient safety review |
| On-Call SRE | PagerDuty: `neurosphere-sre` | Emergency response |

---

*Last updated: 2026-06-20 | Framework version: 2.1.0*
