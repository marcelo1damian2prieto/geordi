# Roadmap

Status: PLANNED

## v0.1 — Platform Core + Self-Observability

COMPLETE
- Core module
- Module registry
- Configurable enable/disable
- Platform health
- Module health
- Minimal React overview
- OpenTelemetry instrumentation
- OpenTelemetry Collector
- Backend quality gates
- Frontend quality gates
- Milestone 1.1 architecture hardening: GitLab CI, self-composed optional modules,
  separated inventory/health evaluation, and build-derived telemetry version

This release corresponds to Milestone 001. It does not include customer telemetry
ingestion, persistence or exploration.

## v0.2 — Metrics Vertical Slice

COMPLETE
- first monitored-workload telemetry capability;
- agent-instrumented sample Spring Boot service;
- OTLP Collector ingestion into single-node VictoriaMetrics;
- vendor-isolated query port/adapter and fixed Metrics APIs;
- JVM and HTTP service-operations view with bounded preset ranges;
- explicit workload/platform classification and pipeline verification.

The release remains intentionally constrained to the fixed Java service-operations
use case.

## v0.3 — Traces + Correlation

COMPLETE
- trace search;
- trace detail;
- span hierarchy;
- Metrics → Traces context navigation.

Trace-related logs were delivered by Milestone 5.

## Milestone 4 — Lightweight Service Investigation

COMPLETE

- bookmarkable service/environment/absolute-time investigation context;
- fixed RED and JVM/resource evidence from existing Metrics contracts;
- recent, error, and slowest-among-recent trace evidence;
- partial-provider failure isolation;
- context-preserving navigation to existing Trace Detail;
- frontend composition with no backend aggregation or full APM abstraction.

The project owner confirmed the authoritative GitLab pipeline is green.

## Milestone 5 — Logs Vertical Slice

COMPLETE
- logs explorer;
- trace/log correlation;
- Logs evidence in Service Investigation;
- bounded Loki-backed vendor-neutral Logs APIs;
- cardinality-safe structured correlation metadata.

Local verification and independent review passed without a remaining BLOCKER or HIGH
finding. The project owner confirmed the authoritative GitLab pipeline green, including
the Logs semantic smoke in its integration gate.

## Milestone 6 — Service Map / Dependency Discovery

COMPLETE
- bounded, trace-derived observed service-to-service dependencies;
- exact environment and absolute time-range context;
- node navigation to Service Investigation and bounded edge trace evidence;
- deterministic monitored downstream workload and focused semantic smoke.

The map is neither configured nor complete architecture and adds no telemetry storage.
Local backend/frontend quality gates, Compose build, and all five semantic smokes passed.
Independent review reported no BLOCKER or HIGH findings. The project owner confirmed
the updated authoritative GitLab pipeline green with the Service Map semantic smoke in
its integration gate.

## Milestone 7 — SLO Foundations

COMPLETE

- read-only, deployment-managed YAML catalog bounded to 50 definitions;
- availability and error-rate objectives over canonical whole-window request outcomes;
- fixed 5-minute, 15-minute, 1-hour, and 6-hour windows;
- explainable `MET`, `BREACHED`, and `UNAVAILABLE` results;
- `/slos`, read-only SLO APIs, and exact-context Service Investigation navigation;
- low-cardinality self-observability and a deterministic semantic smoke in the GitLab
  integration gate.

This milestone does not deliver runtime definition CRUD, latency objectives, long-window
compliance/error budgets, alert notifications, or incident lifecycle. Local verification
and independent review passed without an unresolved BLOCKER or HIGH finding. The SLO
semantic smoke is part of the authoritative GitLab integration gate after the five
existing regression smokes, and the project owner confirmed that pipeline green.

## Later — Alerts

DEFERRED
- threshold alerts;
- webhook/email notifications.

## Later

DEFERRED
- Kubernetes;
- RUM;
- synthetic monitoring;
- profiling;
- migration assistant;
- Datadog/Dynatrace importers;
- AI-assisted root cause analysis.
