# Milestone 001 — Platform Core + Self-Observability

Status: COMPLETE

## Goal

Create the smallest runnable vertical slice proving modular architecture, module discovery, health, backend/frontend integration, OpenTelemetry instrumentation and reproducible local startup.

## Scope

- Spring Boot backend;
- core module;
- self-observability module;
- module registry;
- configurable enable/disable behavior;
- platform/module health endpoints;
- minimal React overview;
- OpenTelemetry backend instrumentation;
- OpenTelemetry Collector;
- Docker/local developer workflow;
- quality gates and tests.

## Non-goals

- production telemetry storage;
- logs explorer;
- trace explorer;
- APM;
- Kubernetes;
- Kafka;
- AI;
- Datadog/Dynatrace migration;
- dynamic runtime plugin loading.
- customer application telemetry ingestion;
- operational log ingestion, storage or exploration.

## Required APIs

- `GET /api/platform`
- `GET /api/modules`
- `GET /api/platform/health`

All product endpoints return HTTP 200 when the backend can answer, including when the
reported platform status is `DOWN`. Actuator readiness uses operational HTTP status
codes independently.

### `GET /api/platform`

```json
{
  "id": "geordi",
  "name": "Geordi",
  "version": "0.1.0-SNAPSHOT"
}
```

### `GET /api/modules`

```json
{
  "modules": [
    {"id": "core", "name": "Core", "enabled": true, "status": "UP"},
    {"id": "self-observability", "name": "Self Observability", "enabled": true, "status": "UP"}
  ]
}
```

### `GET /api/platform/health`

```json
{
  "status": "UP",
  "modules": [
    {"id": "core", "name": "Core", "enabled": true, "status": "UP"},
    {"id": "self-observability", "name": "Self Observability", "enabled": true, "status": "UP"}
  ]
}
```

The contract is also maintained as a static OpenAPI document. Module order is by id.
Allowed statuses are `UP`, `DOWN`, `UNKNOWN` and `DISABLED`. Disabled modules remain
listed, are not health-checked and do not degrade platform health. Any enabled `DOWN`
module makes platform status `DOWN`; otherwise any enabled `UNKNOWN` makes it
`UNKNOWN`; otherwise it is `UP`. Exceptions from a module health check are isolated and
reported as `DOWN` without exposing exception details.

## Configuration contract

```yaml
geordi:
  modules:
    core:
      enabled: true
    self-observability:
      enabled: true
```

Missing module settings default to enabled. `core` is mandatory; configuring it false
fails startup. Configuration for an unknown module id and invalid boolean values also
fail startup to prevent silent typos. Disabling `self-observability` disables its
capability projection but not baseline Actuator, structured logs or instrumentation.

## OpenTelemetry verification contract

- a version-pinned Java Agent exports HTTP/JVM traces and metrics using OTLP/HTTP;
- Collector OTLP receivers listen on 4317 and 4318 inside the local network;
- Collector health is exposed on 13133 and internal metrics on 8888;
- Collector debug output is the terminal local exporter for traces and metrics;
- backend Resource attributes follow `SELF_OBSERVABILITY.md`;
- `OTEL_LOGS_EXPORTER=none` and no Collector logs pipeline are configured;
- an automated, timeout-bounded smoke test verifies Collector readiness, increased
  accepted/exported span and metric counters, zero refused/send-failed deltas, resource
  identity and a JVM metric in Collector output;
- Collector internal telemetry is never sent to its own OTLP receiver.

## Implementation sequence

1. Reconcile architecture/documentation.
2. Write backend behavior tests first for module registration/configuration and health aggregation.
3. Implement backend core and self-observability module.
4. Add ArchUnit dependency tests.
5. Add PMD, SpotBugs and Find Security Bugs gates.
6. Add OpenTelemetry instrumentation and Collector configuration.
7. Validate the documented backend API contract.
8. Implement minimal React overview against real API.
9. Add frontend lint/typecheck/tests.
10. Add reproducible local startup.
11. Run all tests/builds.
12. Run independent reviewer agent.
13. Fix BLOCKER/HIGH findings.
14. Synchronize docs.

## Backend tests

Minimum:
- module registration;
- enabled module behavior;
- disabled module behavior;
- health aggregation;
- REST endpoints;
- architectural dependency rules.
- duplicate module id rejection and deterministic order;
- mandatory core enforcement and unknown configuration rejection;
- disabled-module health isolation and health-check exception isolation.

## Manual verification

- start local environment;
- call all three APIs;
- verify frontend reflects backend state;
- generate backend requests;
- verify Collector receives Geordi backend platform telemetry;
- verify platform telemetry is identifiable as self/platform telemetry.
- verify Actuator liveness/readiness and Collector health separately;
- run the automated OTLP smoke test and verify anti-loop topology.

## Acceptance criteria

1. Clean checkout builds.
2. Backend starts.
3. Frontend starts.
4. Platform API works.
5. Module registry works.
6. Modules can be disabled/enabled through configuration.
7. Health API works.
8. Frontend displays real module health.
9. Backend emits OpenTelemetry data.
10. Collector receives and debug-exports Geordi backend spans and JVM metrics.
11. Self telemetry is identifiable.
12. Backend tests pass.
13. ArchUnit tests pass.
14. PMD passes.
15. SpotBugs/FindSecBugs passes.
16. Frontend Vitest, typecheck, lint and build pass.
17. Startup documentation is reproducible.
18. Collector health/internal telemetry and the automated OTLP smoke test pass.
19. Anti-loop topology is present: no internal self-export, scrape-back or logs pipeline.
20. Documentation matches the implementation.
21. Reviewer reports no unresolved BLOCKER/HIGH findings.

## Risks

- overengineering module abstractions;
- coupling domain to Spring or telemetry vendors;
- introducing storage decisions too early;
- adding tests that assert implementation instead of behavior;
- telemetry feedback loops.

## Recovery

Changes should remain small and milestone-scoped. If an architectural choice blocks progress, record a new ADR before widening scope.

## Completion evidence

- backend: 20 tests pass, including ArchUnit and UNKNOWN/readiness regression;
- backend quality gates: PMD passes; SpotBugs and Find Security Bugs report zero
  findings;
- frontend: 2 Vitest tests, typecheck, ESLint and Vite build pass;
- Java 21 backend and frontend container images build successfully;
- Collector configuration validates and all three Compose services become healthy;
- all product APIs, Actuator probes, frontend and frontend API proxy return HTTP 200;
- disabling `self-observability` reports `DISABLED` without degrading platform health;
- the final OTLP smoke increased accepted/exported spans by 12/12 and metric points by
  47/47, with no refused or send-failed increase and with Resource/JVM evidence;
- independent review found no BLOCKER and one HIGH; the HIGH was fixed and covered by
  regression tests, leaving no unresolved BLOCKER/HIGH findings;
- Git metadata was absent from the supplied workspace, so clean-checkout provenance
  could not be inspected; reproducible wrapper, lockfile, container and CI builds were
  verified from the complete working tree.
