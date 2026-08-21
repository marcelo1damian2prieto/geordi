# Geordi

**Geordi** is a modular, OpenTelemetry-native observability platform.

> Working codename. The public/commercial name should be reviewed separately before release.

## Product principles

1. **Modular by Design** — companies enable only the capabilities they need.
2. **OpenTelemetry Everywhere** — OTLP/OpenTelemetry is the canonical telemetry model.
3. **The Observer Must Be Observable** — Geordi monitors its own health and telemetry pipeline.
4. **Replaceability by Design** — coexist with and progressively replace existing observability stacks.

## Engineering approach

- Pragmatic TDD
- Domain-Driven Design where real domain rules exist
- Hexagonal Architecture at external boundaries
- Modular monolith first
- Architecture rules enforced with ArchUnit
- Static analysis and security gates from the beginning

## Initial stack

### Backend
- Java
- Spring Boot
- Maven
- JUnit 5 / AssertJ
- ArchUnit
- PMD
- SpotBugs
- Find Security Bugs

### Frontend
- React
- TypeScript
- Vite
- TanStack Query
- ECharts
- TanStack Table
- ESLint / typescript-eslint
- Vitest / React Testing Library

### Telemetry
- OpenTelemetry
- OTLP
- OpenTelemetry Collector

### Local runtime
- Docker Compose

## Milestones 1 / 1.1 — COMPLETE

**Platform Core + Self-Observability**

The foundation proves:
- modular architecture;
- module registry;
- enable/disable configuration;
- platform/module health;
- backend/frontend integration;
- OpenTelemetry instrumentation;
- Collector reception;
- reproducible local startup.

Milestone 1.1 hardens that foundation with generic optional-module composition,
side-effect-free module inventory, separate health evaluation, build-derived version
propagation, and equivalent GitHub/GitLab quality gates.

## Milestone 2 — Metrics vertical slice

**COMPLETE.** A demo Spring Boot service emits OTLP metrics through the Collector into
VictoriaMetrics; Geordi queries that store through a replaceable adapter and exposes a
fixed service-operations view at `/metrics`.

The slice covers JVM memory, CPU, threads and GC plus HTTP request volume/rate, p95
latency and errors. It is not a generic explorer, dashboard builder, APM implementation
or multi-provider storage layer.

## Milestone 3 — Traces vertical slice

**COMPLETE.** The demo exports OTLP traces through the Collector into Tempo. Geordi
discovers and searches traces by the exact monitored service identity and time range,
exposes complete trace detail, and renders a simple span waterfall at `/traces`. The
Metrics view links to Traces while preserving service, environment, namespace and the
absolute investigation range.

## Milestone 4 — Lightweight Service Investigation

**COMPLETE.** The `/investigate` workflow composes the existing Metrics and Traces APIs
around one exact service namespace, name, environment, and absolute time range. The
milestone delivers:

- canonical, bookmarkable investigation context;
- RED and JVM/resource evidence;
- recent, slowest-among-recent, and error traces;
- independent partial-failure isolation;
- stale-data protection across identity and range changes;
- context-preserving Investigation → Trace Detail → Investigation navigation.

Milestone 4 itself added no backend aggregation API, Logs capability, full APM, or new
telemetry infrastructure. Its local verification, independent review, and authoritative
GitLab CI gate are green.

## Milestone 5 — Logs vertical slice

**COMPLETE.** The demo emits OTLP Logs through the Collector into
Grafana Loki 3.7.2. Geordi exposes a bounded, vendor-neutral Logs API and `/logs` UI
for one exact monitored service identity and absolute range, with severity, literal
text, and trace/span correlation filters. Trace Detail can open related Logs with valid
carried context, and Service Investigation composes an independently failing Logs
section alongside Metrics and Traces.

Loki is isolated behind the Logs query port. Only `service.name`,
`service.namespace`, `deployment.environment.name`, and `geordi.telemetry.origin` are
Loki labels; correlation IDs and other high-cardinality data remain structured metadata.
Local acceptance criteria passed, independent review completed without a remaining
BLOCKER or HIGH finding, and the project owner subsequently confirmed the authoritative
GitLab pipeline green. Its integration gate includes the Logs semantic smoke.

## Milestone 6 — Service Map / Dependency Discovery

**COMPLETE.** `/service-map` and `GET /api/service-map` derive a bounded,
directed service-to-service graph from available monitored trace evidence. An edge means
an exact monitored `CLIENT` parent directly called a distinct monitored `SERVER` child
whose server start is inside the selected environment and absolute `[from,to)` range.
It is observed evidence, not configured or complete architecture; an absent edge does
not prove an absent dependency.

The local runtime includes a deterministic monitored downstream workload for this
semantic path. The graph uses no additional telemetry store, preserves exact
namespace/name/environment identity, bounds candidate/detail work and returned graph
size, and exposes bounded representative trace evidence. Local backend/frontend gates,
Compose build, all five semantic smokes, and independent review have passed with no
BLOCKER or HIGH findings. The project owner confirmed the updated authoritative GitLab
pipeline green, including the Service Map semantic smoke in its integration gate.

## Milestone 7 — SLO Foundations

**COMPLETE.** Geordi
loads at most 50 deployment-managed SLO definitions from the read-only YAML catalog at
`deploy/slos/slos.yaml`, exposes read-only definition/evaluation APIs, and presents
current results at `/slos`. Catalog changes require a backend restart or redeployment;
there is no runtime CRUD API or form.

The supported objectives use one canonical whole-window Metrics request-outcome
boundary:

- availability `(requests - 5xx errors) / requests`, met at `observed >= target`;
- error rate `5xx errors / requests`, met at `observed <= target`.

Targets are ratios from `0` to `1`, equality is met, and windows are limited to `PT5M`,
`PT15M`, `PT1H`, and `PT6H`. Evaluations distinguish `MET`, `BREACHED`, and
`UNAVAILABLE`; bounded reasons distinguish disabled definitions, no traffic, missing or
invalid counts, and Metrics unavailability. Provider syntax remains in the
VictoriaMetrics adapter. Latency SLOs, scheduling, history, long-period error-budget
accounting, notifications, and incident management are not implemented.

Milestone 8 is **READY FOR GITLAB REVALIDATION**. It enriches the same on-demand SLO snapshot
with SLI-aware current-window error-budget evidence: allowed and observed bad-event
ratios plus a dimensionless burn rate. It does not provide error-budget remaining,
long-period compliance accounting, alerts, notifications, incidents, storage, or a
scheduler.

## Current capabilities

- **Metrics:** OTLP Metrics → Collector → VictoriaMetrics → vendor-neutral Metrics
  query layer → REST API → React Metrics UI.
- **Traces:** OTLP Traces → Collector → Tempo → vendor-neutral Traces query layer →
  REST API → React Traces UI.
- **Logs:** OTLP Logs → Collector → Loki → vendor-neutral Logs query layer → REST API
  → React Logs UI.
- **Correlation:** Metrics → service/environment/time context → Traces; Trace Detail →
  related Logs when valid context and trace correlation are available.
- **Service investigation:** `/investigate` → fixed RED/JVM evidence plus relevant
  traces and recent Logs for one canonical, bookmarkable context.
- **Service Map:** `/service-map` → trace-derived observed dependencies
  for one exact environment and bounded absolute range; node navigation reuses
  Investigation and edge evidence reuses Trace Detail.
- **SLO foundations:** deployment-managed definitions → canonical whole-window request
  outcomes → explainable on-demand status at `/slos`; Investigation navigation preserves
  the exact service identity and returned absolute evaluation range.
- **Current-window error-budget burn (M8 ready for GitLab revalidation):** the same SLO snapshot exposes
  allowed bad-event ratio, observed bad-event ratio, and finite burn evidence when
  valid; it is not compliance-period budget accounting.

This is a bounded service-investigation foundation, not full APM.

## Run locally

Prerequisites: Docker Desktop with Compose.

```powershell
Copy-Item .env.example .env
docker compose up --build
```

Open the Platform Overview at `http://127.0.0.1:3000`. The backend API is available
at `http://127.0.0.1:8080`.

Verify the complete self-telemetry path:

```powershell
.\scripts\verify-otel.ps1
```

The smoke test verifies backend and Collector readiness separately, generates traffic,
proves that spans and JVM metrics are accepted and debug-exported without refused or
failed telemetry, and requires telemetry `service.version` to match the platform API.

Verify monitored-service ingestion, persistence and the Geordi query APIs:

```powershell
.\scripts\verify-metrics.ps1
```

This smoke generates predictable demo traffic, checks Collector failure/loss counters,
queries stored OTel metrics, and exercises the service, overview and series APIs.

Verify trace ingestion, persistence, search, detail and correlation semantics:

```powershell
.\scripts\verify-traces.ps1
```

Verify Logs ingestion, exact identity/range/severity semantics, correlation, and the
absence of high-cardinality Loki labels:

```powershell
.\scripts\verify-logs.ps1
```

Run the Service Map semantic smoke after the Compose stack is ready. It generates
propagated demo-to-downstream traffic and checks the exact directed trace-derived edge,
bounded evidence, and frontend/API proxy path. It passed during Milestone 6 local
verification and is included in the authoritative GitLab stack-smoke job. The project
owner confirmed that updated pipeline green.

```powershell
.\scripts\verify-service-map.ps1
```

Run the Milestone 7 semantic smoke after the Compose stack is ready. It checks the
mounted catalog, exact identities, real whole-window Metrics evidence, deterministic
`MET`, `BREACHED`, and no-traffic `UNAVAILABLE` outcomes, provider-failure behavior,
provider-neutral API/frontend proxy responses, and SLO → Investigation context.

```powershell
.\scripts\verify-slos.ps1 -ExerciseProviderFailure
```

The SLO smoke and its full regression run are configured in GitLab CI. The complete
local CI-equivalent run and independent review passed, and the project owner confirmed
the authoritative GitLab pipeline green.

The M8 burn-rate smoke uses an isolated monitored workload, independently recomputes
ratio and burn evidence from persisted Metrics, checks unavailable and zero-allowed-ratio
behavior, and preserves the returned Service Investigation context.

```powershell
.\scripts\verify-burn-rate.ps1 -ExerciseProviderFailure
```

M8 is **READY FOR GITLAB REVALIDATION**. Its complete local CI-equivalent verification
and independent review passed without a remaining BLOCKER or HIGH finding. It must not
be called complete before the project owner confirms the authoritative GitLab pipeline
is green.

## Quality gates

```powershell
cd backend
.\mvnw.cmd verify

cd ..\frontend
npm ci
npm run test
npm run typecheck
npm run lint
npm run build
```

GitHub Actions and GitLab CI share the backend and frontend quality gates. GitLab's
authoritative deployment and complete stack-smoke jobs additionally use a trusted
Windows runner tagged `geordi-docker-pwsh` with Docker daemon access, Docker Compose v2,
PowerShell 7, outbound image access, and the fixed local ports available. The integration
job is serialized by a resource group and runs the self-observability, Metrics, Traces,
Logs, Service Map, SLO, and burn-rate semantic smokes in that order.

Milestones 1 / 1.1 and 2 through 7 are complete. Milestone 7 passed complete local
verification and independent review without a remaining BLOCKER or HIGH finding. Its
SLO semantic smoke runs after the five existing regression smokes in the authoritative
GitLab integration gate, and the project owner confirmed that pipeline green.

M8's burn-rate smoke follows the M7 smoke in the same job. M8 is **READY FOR GITLAB
REVALIDATION** after all mandatory local gates and independent review passed;
authoritative GitLab green and project-owner confirmation remain its completion gate.

## Documentation

See:
- `docs/product/`
- `docs/architecture/`
- `docs/adr/`
- `docs/plans/`
