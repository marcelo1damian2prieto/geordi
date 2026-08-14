# Geordi Product Requirements Document

Status: FOUNDATION IMPLEMENTED / FUTURE CAPABILITIES PLANNED

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

## Planned capabilities

- core platform;
- metrics;
- logs;
- traces;
- APM;
- infrastructure monitoring;
- service map;
- alerts;
- compatibility/migration;
- self-observability;
- future AI-assisted incident analysis.

## Milestone 1 scope

Status: IMPLEMENTED

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

Status: LOCAL IMPLEMENTATION / PENDING GITLAB REVALIDATION

Milestone 4 composes the existing Metrics and Traces capabilities into one fixed,
service-centric `/investigate` workflow. Operators carry an exact namespace/name/
environment identity and one absolute range across RED metrics, JVM/resource signals,
recent traces, error traces, duration-ordered recent traces, and existing Trace Detail.
Missing telemetry, valid zero, empty results, provider failures, and stale context
transitions remain distinct.

Composition is frontend-only. Milestone 4 does not add Logs, backend aggregation, full
APM, dashboards/widgets, service maps, alerts/SLOs, anomaly detection, new providers,
infrastructure product features, arbitrary query languages, or Milestone 5 work.

Local success does not complete the milestone. Its maximum local status is `READY FOR
GITLAB REVALIDATION`; the project owner must confirm the authoritative GitLab pipeline.
