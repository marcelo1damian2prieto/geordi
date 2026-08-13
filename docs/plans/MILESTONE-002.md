# Milestone 002 — Metrics Vertical Slice

Status: COMPLETE

## Objective

Deliver the smallest useful end-to-end metrics capability for a monitored
Java/Spring Boot service:

```text
demo workload -> OTLP -> OpenTelemetry Collector -> VictoriaMetrics
                                                     ^
                                                     |
React <- REST <- Metrics application <- query port <- adapter
```

The slice proves real ingestion, persistence, vendor-isolated querying and
visualization without becoming a dashboard builder, metrics explorer or APM product.

## User story

As an operator, I can select a monitored Java service and a recent time range and see
its JVM and HTTP operational metrics so that I can quickly assess runtime health.

## Reconciled decisions

- One modular-monolith `metrics` bounded context; ingestion remains deployment
  infrastructure and no write repository is added to the backend.
- VictoriaMetrics single-node is the one Milestone 2 store (ADR-008).
- The Collector exports metrics by OTLP/HTTP directly to VictoriaMetrics while
  retaining local debug export for Milestone 1 smoke evidence.
- A fixed Geordi operational-metric catalog and composite OTel service identity form
  the canonical query boundary (ADR-009). Raw MetricsQL/PromQL and arbitrary labels
  never cross the adapter.
- Workload identity is `(service.namespace, service.name,
  deployment.environment.name)` and uses `geordi.telemetry.origin=monitored`.
- The UI offers bounded presets (15 minutes, 1 hour and 6 hours); the backend accepts
  any valid range up to six hours, selects resolution and caps returned points.
- The Metrics `PlatformModule` is always registered. Capability beans and routes exist
  only when `geordi.modules.metrics.enabled=true` (the default).
- Health performs a bounded real query through the backend adapter. Inventory never
  performs health or storage I/O.
- The UI is a fixed service-operations view with seven metric concepts and explicit
  loading, empty and failure states.

## Metric semantics

The adapter maps these OTel instruments to fixed product views:

| Product view | OTel source | Canonical result |
|---|---|---|
| JVM memory used | `jvm.memory.used` | total bytes across reported pools |
| JVM CPU utilization | `jvm.cpu.recent_utilization` | ratio `[0,1]` |
| JVM threads | `jvm.thread.count` | thread count |
| JVM GC duration | `jvm.gc.duration` | duration rate/total in seconds |
| HTTP request rate/count | `http.server.request.duration` histogram count | requests/s and count |
| HTTP p95 latency | `http.server.request.duration` histogram | approximate p95 seconds |
| HTTP error rate/count | HTTP duration series with 5xx/error attributes | ratio and count |

HTTP stable semantic conventions and cumulative OTLP temporality are explicit runtime
configuration. Missing optional telemetry is empty, never synthesized as zero.

## Implementation phases

### Phase A — decisions and contracts

- [x] Inspect repository, Git status, docs, ADRs and current implementation.
- [x] Reconcile architect, product, observability, backend, frontend and DevOps analysis.
- [x] Record storage and canonical-query ADRs.
- [x] Finalize OpenAPI contracts before frontend production work.

### Phase B — backend (test-first)

- [x] Add pure time range, service identity, metric catalog, point and series types.
- [x] Add query/probe ports and application service with bounded resolution.
- [x] Add VictoriaMetrics query translation/parsing adapter with strict timeouts.
- [x] Add module-owned activation, REST/error mapping, health and query telemetry.
- [x] Extend ArchUnit and unit/API/adapter tests.

### Phase C — runtime vertical slice

- [x] Add pinned VictoriaMetrics single-node with persistent local volume and health.
- [x] Export Collector metrics through direct OTLP/HTTP with retry/queue enabled.
- [x] Add a small agent-instrumented Spring Boot demo with success/error/latency routes.
- [x] Add workload generation and persistence/API smoke verification.
- [x] Preserve the existing trace/self-observability verification.

### Phase D — frontend

- [x] Add `/metrics` navigation and fixed service operations view.
- [x] Add service and 15m/1h/6h selectors using one aligned absolute range.
- [x] Add overview cards and seven accessible ECharts visualizations.
- [x] Add loading, no-service, no-data, partial-data and backend-error behavior/tests.

### Phase E — documentation and verification

- [x] Update README, product, architecture, self-observability, modules and OpenAPI docs.
- [x] Run Maven verify including PMD, SpotBugs, Find Security Bugs and ArchUnit.
- [x] Run frontend tests, typecheck, ESLint and production build.
- [x] Validate Compose; start stack; verify storage, ingestion, APIs and frontend route.
- [x] Run independent reviewer; fix every BLOCKER/HIGH finding and assess MEDIUM items.

## Completion evidence

- Backend `mvnw verify`: 53 tests; 6 ArchUnit rules; PMD passed; SpotBugs and
  Find Security Bugs reported zero findings.
- Frontend: 12 Vitest tests, TypeScript typecheck, ESLint and production build passed.
- Compose model and Collector configuration validated; all five local services reached
  healthy state.
- Existing `verify-otel.ps1` passed without regression.
- Strengthened `verify-metrics.ps1` passed for Collector no-loss counters, persisted
  OTel metric families, all nine canonical Geordi metrics and units, finite values,
  ratio bounds, positive success/error traffic, frontend `/metrics`, and nginx proxy.
- Independent review found no BLOCKERs. All four HIGH findings were fixed and verified:
  null-namespace isolation, GC duration semantics, selected-range count semantics, and
  full-catalog test/smoke assertions.
- Selected MEDIUM/LOW items fixed: stale cross-selection frontend data, 10-second
  minimum rollups, OpenAPI disabled/empty behavior, frontend/proxy smoke, and
  documentation scope drift. Remaining items are recorded below.

## Known limitations / follow-up

- VictoriaMetrics calls are sequential; a backend outage can multiply the per-call
  timeout during a nine-metric overview. Add an overall deadline or bounded parallelism.
- Zero-error periods may appear as absent error series when no 5xx numerator exists;
  coalesce only when request telemetry is known to exist.
- Probe availability is recorded as outcome counters rather than a current gauge, and
  service discovery result count shares a generic result-count instrument.
- `GeordiModulesProperties` now allows sibling `geordi.*` namespaces; activation typo
  behavior should be re-hardened without coupling bootstrap to provider configuration.
- Route-level ECharts lazy loading remains technical debt.

## Acceptance and evidence

The 38 acceptance criteria in the Milestone 2 brief are authoritative. Completion
evidence must include exact commands/results for backend gates, frontend gates,
Compose validation/startup, VictoriaMetrics health, demo workload telemetry,
Collector accepted/sent/refused/failed counters, stored series, Geordi Metrics APIs,
the rendered frontend route and retained Milestone 1 OTel smoke verification.

## Explicit non-goals

No generic explorer or dashboard editor, logs, trace UI/correlation, APM, service map,
alerts/SLOs, RUM, synthetics, Kubernetes, Kafka, tenancy, auth redesign, migration
adapter, multiple stores, or AI/RCA is part of this milestone.
