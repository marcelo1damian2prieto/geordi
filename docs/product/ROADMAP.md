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

## Milestone 8 — Error Budget & Burn Rate Foundation

COMPLETE

- one derived atomic current-window burn snapshot in the existing SLO evaluation;
- SLI-aware allowed bad-event ratio, observed bad-event ratio, and dimensionless burn
  rate over the same exact canonical identity and returned absolute range;
- explicit `AVAILABLE`/`UNAVAILABLE` burn semantics, including safe zero-allowed-ratio
  handling without NaN or infinity;
- `/slos` explanation, accessible availability state, and existing exact-context Service
  Investigation navigation;
- low-cardinality self-observability and an isolated semantic smoke after the M7 smoke
  in the authoritative GitLab integration job.

It does not add remaining-budget claims, long-period compliance accounting, storage,
history, scheduling, alerting, notifications, incidents, or Milestone 9 functionality.
Required local verification and independent review passed without a remaining BLOCKER
or HIGH finding. The authoritative GitLab pipeline passed the complete OpenTelemetry,
Metrics, Traces, Logs, Service Map, SLO, and Burn Rate smoke chain, including isolated
valid-zero and elevated burn evidence, exact-window independent recomputation,
unavailable semantics, provider failure and recovery, Investigation context, and bounded
burn telemetry.

## Milestone 9 — Alert Evaluation Foundation

COMPLETE

- read-only deployment-managed policies over canonical M8 burn evidence;
- one inclusive `BURN_RATE_ABOVE` condition with explainable `CONDITION_MET`,
  `CONDITION_NOT_MET`, or `UNAVAILABLE` results;
- exact SLO identity/window evidence and Service Investigation navigation;
- no notification delivery, page, incident, persistent lifecycle, scheduler, or generic
  rule engine.

Mandatory local verification and independent review passed without a remaining BLOCKER
or HIGH finding. The authoritative GitLab pipeline passed the Service Map, SLO, Burn
Rate, and Alert Evaluation verification chain. The M9 smoke intentionally reuses the
Burn Rate gate's VictoriaMetrics outage/recovery evidence instead of duplicating that
expensive scenario.

## Milestone 10 — Alert Lifecycle Foundation

COMPLETE

- durable single-node `INACTIVE`/`FIRING` state over canonical M9 evaluation;
- explicit state-changing POST and side-effect-free current-state GET;
- canonical `ALERT_STARTED`/`ALERT_RESOLVED` transitions with unavailable/disabled
  freezing;
- file-backed H2/Flyway persistence, optimistic concurrency, restart proof, exact
  Investigation context, and bounded self-observability;
- no scheduler, history, delivery, acknowledgement, silencing, or incident workflow.

The Alert Lifecycle Persistence Health fix is complete. The authoritative GitLab
semantic chain checked out commit `4a81d9f8` and passed the M8 Burn Rate, M9 Alert
Evaluation, and M10 Alert Lifecycle smokes with no remaining BLOCKER or HIGH finding.

Milestone 11 is COMPLETE. It adds an atomic transactional outbox,
bounded restart-safe webhook worker, stable delivery identity, bounded retries, and
low-cardinality delivery telemetry without scheduling alert evaluation.

## Milestone 11 — Notification delivery

COMPLETE
- webhook delivery foundation;
- email and provider-specific adapters remain deferred.

Authoritative GitLab semantic revalidation on `main` at commit `f087da71` passed M9
Alert Evaluation, M10 Alert Lifecycle, and M11 Notification Delivery with no remaining
BLOCKER or HIGH finding.

## Milestone 12 — Automated alert evaluation scheduling

READY FOR GITLAB REVALIDATION

M12 introduces bounded single-node, deployment-managed automatic evaluation through the
existing M9 evaluation, M10 lifecycle, and M11 delivery boundaries. It has no distributed
coordination, leader election, missed-tick replay, policy reload, arbitrary cadence, or
new API/UI. Final completion remains conditional on authoritative GitLab revalidation.

## Later

DEFERRED
- Kubernetes;
- RUM;
- synthetic monitoring;
- profiling;
- migration assistant;
- Datadog/Dynatrace importers;
- AI-assisted root cause analysis.
