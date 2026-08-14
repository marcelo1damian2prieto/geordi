# Roadmap

Status: PLANNED

## v0.1 — Platform Core + Self-Observability

IMPLEMENTED
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

Trace-related logs are delivered by Milestone 5 and remain subject to its GitLab
revalidation status.

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

READY FOR GITLAB REVALIDATION
- logs explorer;
- trace/log correlation;
- Logs evidence in Service Investigation;
- bounded Loki-backed vendor-neutral Logs APIs;
- cardinality-safe structured correlation metadata.

Local verification does not complete the milestone. The authoritative GitLab pipeline
must be green and confirmed by the project owner before the status may become
`COMPLETE`.

## Later — Service Map + Alerts

DEFERRED
- service dependency topology;
- threshold alerts;
- webhook/email notifications.

## Later

DEFERRED
- Kubernetes;
- RUM;
- synthetic monitoring;
- SLOs;
- profiling;
- migration assistant;
- Datadog/Dynatrace importers;
- AI-assisted root cause analysis.
