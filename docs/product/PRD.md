# Geordi Product Requirements Document

Status: MILESTONES 1 THROUGH 7 COMPLETE

## Vision

Geordi is a modular, OpenTelemetry-native observability platform that helps organizations understand distributed systems while preserving interoperability and minimizing vendor lock-in.

## Problem

Organizations commonly face one or more of these problems:
- fragmented metrics, logs and traces;
- expensive or inflexible SaaS observability platforms;
- operational complexity in open-source stacks;
- vendor-specific instrumentation and query models;
- disruptive migrations between observability products;
- poor visibility into the observability platform itself.

## Product proposition

Geordi combines:
- a unified observability experience;
- modular deployment;
- open telemetry standards;
- compatibility with existing systems;
- self-observability;
- gradual migration paths.

## Core principles

1. Modular by Design.
2. OpenTelemetry Everywhere.
3. The Observer Must Be Observable.
4. Replaceability by Design.

## Deployment modes

### Overlay
Geordi provides a unified experience over existing observability infrastructure.

### Hybrid
Some signals/providers are owned by Geordi and others remain external.

### Full Replacement
Geordi owns the complete telemetry path and user experience.

## Capabilities

- core platform;
- metrics;
- logs;
- traces;
- APM;
- infrastructure monitoring;
- service map;
- service-level objectives;
- alerts;
- compatibility/migration;
- self-observability;
- future AI-assisted incident analysis.

## Milestone 1 scope

Status: COMPLETE

Milestone 1 provides:
- platform core;
- module abstraction/registry;
- enable/disable configuration;
- platform/module health;
- backend API;
- minimal frontend overview;
- OpenTelemetry self-instrumentation;
- local OpenTelemetry Collector.

Milestone 1 does not ingest, persist, query or present customer telemetry. Collector
reception is verified only for Geordi platform telemetry.

DEFERRED:
- telemetry storage;
- metrics explorer;
- logs explorer;
- trace explorer;
- APM;
- service map;
- alert evaluation;
- Kubernetes;
- AI;
- vendor-specific migration adapters.

## Milestone 2 scope

Status: COMPLETE

Milestone 2 adds the first monitored-workload telemetry path. A sample Spring Boot
service emits OpenTelemetry JVM and HTTP metrics through the Collector to one persistent
store. Geordi lists monitored services and returns a fixed operational overview and
bounded series through a vendor-neutral query boundary. React presents the same fixed
concepts with service/range selection and explicit loading, empty and failure states.

Milestone 2 does not provide arbitrary metric queries, editable/saved dashboards, APM,
logs, traces, correlation, service maps, alerts, SLOs, tenancy, Kubernetes, AI or
provider migration.

## Milestone 3 scope

Status: COMPLETE

Milestone 3 adds persistent distributed traces through Tempo behind a vendor-neutral
query port. Operators can discover and search an exact monitored service identity in a
bounded time range, inspect complete span hierarchy/timing/error data, and move from
Metrics to Traces with the same canonical context.

Milestone 3 does not add logs, full APM, service maps, alerting, arbitrary TraceQL,
saved searches, multiple trace stores, tenancy, Kubernetes, AI or Milestone 4 work.

## Milestone 4 scope

Status: COMPLETE

Milestone 4 composes the existing Metrics and Traces capabilities into one fixed,
service-centric `/investigate` workflow. Operators carry an exact namespace/name/
environment identity and one absolute range across RED metrics, JVM/resource signals,
recent traces, error traces, duration-ordered recent traces, and existing Trace Detail.
Missing telemetry, valid zero, empty results, provider failures, and stale context
transitions remain distinct.

Composition is frontend-only. Milestone 4 does not add Logs, backend aggregation, full
APM, dashboards/widgets, service maps, alerts/SLOs, anomaly detection, new providers,
infrastructure product features, arbitrary query languages, or Milestone 5 work.

The project owner confirmed the authoritative GitLab pipeline for Milestone 4 is green.

## Milestone 5 scope

Status: COMPLETE

Milestone 5 adds the bounded Logs vertical slice: a demo workload emits OTLP Logs to
the Collector and Loki; Geordi queries Loki through a vendor-neutral port/adapter and
serves `/api/logs/services`, `/api/logs`, and `/logs`. Operators use one exact monitored
service identity and absolute range, filter with canonical severity or literal text,
and inspect record body, attributes, and available trace/span correlation.

Service Investigation composes Logs independently with Metrics and Traces. Trace Detail
opens related Logs only with valid carried identity/range context and trace correlation.
No LogQL reaches the public API or UI. Loki labels are limited to low-cardinality
service/environment/origin fields; correlation IDs and arbitrary fields remain
structured metadata.

Milestone 5 does not add service maps, alerts, dashboards, saved searches, arbitrary
query languages, multiple providers, advanced retention, multi-tenancy, Kubernetes,
APM, or AI/RCA. Local acceptance criteria and independent review passed without a
remaining BLOCKER or HIGH finding. The project owner subsequently confirmed the
authoritative GitLab pipeline green; its integration gate includes Logs semantic
verification.

## Milestone 6 scope

Status: COMPLETE

Milestone 6 adds a bounded Service Map derived only from available monitored traces.
For one exact environment and explicit absolute `[from,to)` range of at most six hours,
an edge means a monitored `CLIENT` span is the direct parent of a monitored `SERVER`
span in a distinct exact namespace/name/environment identity, and the SERVER start is
inside the selected range. The map exposes endpoint nodes, directed deduplicated edges,
distinct-trace evidence counts, up to three representative trace references, and an
explicit truncation flag through `/api/service-map` and `/service-map`.

It is observed evidence, not configured, static, complete, infrastructure, network, or
CMDB topology. Missing edges do not prove that a dependency does not exist. Candidate
and detail retrieval, graph size, and representative evidence are explicitly bounded;
the local Compose runtime adds one deterministic monitored downstream workload and a
focused Service Map smoke for semantic verification. Node navigation reuses Service
Investigation; edge evidence reuses existing Trace Detail.

Milestone 6 does not add a telemetry store, graph database, cache, Logs/Metrics-derived
relationships, async inference, external dependency nodes, edge performance analytics,
alerts/SLOs, generic graph/query engines, or Milestone 7 work. Local backend/frontend
quality gates, Compose build, all five semantic smokes, and independent review passed
with 0 remaining BLOCKER findings and 0 remaining HIGH findings. The Service Map smoke
is part of the authoritative integration gate, and the project owner confirmed the
updated authoritative GitLab pipeline green.

## Milestone 7 scope

Status: COMPLETE

Milestone 7 adds a bounded SLO module over the existing canonical Metrics capability.
The deployment supplies at most 50 definitions through a version-controlled YAML file
mounted read-only into the backend. Operators can list and inspect definitions through
`GET /api/slos` and `GET /api/slos/{id}`, request an on-demand evaluation through
`GET /api/slos/{id}/evaluation`, and inspect results at `/slos`. Definition changes
require restart/redeployment; runtime create, update, and delete are not supported.

The supported SLIs are availability `(N-E)/N`, met when the observed ratio is greater
than or equal to the target, and error rate `E/N`, met when it is less than or equal to
the target. `N` is whole-window request count and `E` whole-window HTTP 5xx count for
one exact monitored namespace/name/environment identity. Targets are ratios in `[0,1]`,
equality is met, and windows are exactly `PT5M`, `PT15M`, `PT1H`, and `PT6H`.

Results expose target, observed ratio when valid, request count, absolute range,
evaluation time, and `MET`, `BREACHED`, or `UNAVAILABLE`. Bounded unavailable reasons
distinguish disabled definitions, no traffic, missing request/error counts, invalid
telemetry, and Metrics unavailability. The UI preserves the returned identity and range
when navigating to Service Investigation. PromQL/MetricsQL and VictoriaMetrics response
types remain confined to the Metrics adapter.

Milestone 7 does not add latency SLOs, arbitrary expressions, runtime CRUD, scheduling,
evaluation history, long-window compliance accounting, error budgets, notifications,
alert lifecycle, incident management, new telemetry storage, or Milestone 8 work. Its
backend/frontend quality gates, deployment/configuration verification, semantic SLO
smoke, Milestones 1 through 6 regression smokes, and independent review passed without
an unresolved BLOCKER or HIGH finding. The semantic SLO smoke is part of the
authoritative GitLab integration gate, and the project owner subsequently confirmed
that pipeline green.
