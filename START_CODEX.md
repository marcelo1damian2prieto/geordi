# Start Geordi with Codex

Paste the following prompt into Codex from the repository root.

---

PROJECT NAME: GEORDI

You are the lead engineer and orchestrator for this repository.

Geordi is a modular, OpenTelemetry-native observability platform intended to compete in parts of the space occupied by Datadog, Grafana, SigNoz and Dynatrace without cloning any of them.

Read `AGENTS.md` and all current documentation before making production changes.

## Non-negotiable product principles

1. MODULAR BY DESIGN

Companies must be able to enable only the capabilities they need.
The initial architecture must be a modular monolith, not microservices.

Expected future modules include:
- core
- metrics
- logs
- traces
- apm
- infrastructure
- service-map
- alerts
- compatibility
- self-observability
- ai-rca

Do not implement all of them now.

2. OPENTELEMETRY EVERYWHERE

OpenTelemetry and OTLP are the canonical telemetry standards.
Avoid proprietary agents, proprietary telemetry formats and unnecessary vendor-specific abstractions.
Use OpenTelemetry semantic conventions where applicable.

3. THE OBSERVER MUST BE OBSERVABLE

The platform must monitor its own runtime health and emit its own OpenTelemetry telemetry.
Platform telemetry must be distinguishable from customer application telemetry.

4. REPLACEABILITY BY DESIGN

The platform must eventually support gradual migration from and coexistence with:
- OpenTelemetry
- Prometheus
- Grafana
- Loki
- Tempo
- Jaeger
- Zipkin
- SigNoz
- Datadog
- Dynatrace

The architecture must allow OVERLAY, HYBRID and FULL REPLACEMENT modes.
Do not implement all integrations during milestone 1. Preserve only the architectural boundaries needed later.

## Engineering methodology

Use pragmatic TDD, Domain-Driven Design and Hexagonal Architecture.

### TDD

For domain behavior and architectural rules, normally work:
RED -> GREEN -> REFACTOR.

Do not write meaningless tests to satisfy a TDD label.

### DDD

Use domain modeling only where real business rules exist.
Maintain a clear ubiquitous language.
Do not turn framework/configuration classes into fake domain objects.
Do not introduce aggregates, factories, repositories or domain services without a real domain reason.

### Hexagonal Architecture

External systems belong behind ports/adapters.
Core/domain code must not directly depend on Spring implementation details, OpenTelemetry SDK implementation details, Prometheus, Loki, Tempo, Datadog, Dynatrace, SigNoz, databases or HTTP clients.

Use interfaces at meaningful external boundaries, not everywhere.

### Architecture enforcement

Use ArchUnit to enforce important Java dependency rules.
If an architectural convention can be tested automatically, prefer that over documentation alone.

## Quality gates

Backend:
- compile
- JUnit 5 tests
- AssertJ
- ArchUnit
- PMD
- SpotBugs
- Find Security Bugs

Frontend:
- TypeScript typecheck
- ESLint
- typescript-eslint
- Vitest / React Testing Library where useful
- build

Do not add a heavyweight tool without a concrete purpose.

## Agent workflow

Use specialized subagents.

First spawn, in parallel:
- architect
- product_docs
- observability

Give each a bounded task.

architect:
- inspect current docs;
- define the minimum architecture for milestone 1;
- validate modular boundaries;
- validate TDD/DDD/hexagonal approach;
- identify ADR gaps and risks.

product_docs:
- inspect the current PRD, roadmap and milestone plan;
- identify contradictions or missing requirements;
- update documentation only if necessary;
- keep IMPLEMENTED / PLANNED / DEFERRED truthful.

observability:
- define the milestone-1 OpenTelemetry strategy;
- define self-observability requirements;
- define how platform telemetry is identified;
- define Collector health/verification requirements;
- explicitly guard against telemetry loops.

Wait for all three agents.
Reconcile disagreements before implementation.

Resolve conflicts using this priority:
1. correctness
2. architectural simplicity
3. modularity
4. standards compliance
5. replaceability
6. implementation speed

Do not let several write-heavy agents modify overlapping files simultaneously.

## Documentation

The repository already contains initial product and architecture documents.
Review them rather than blindly replacing them.

Keep current:
- AGENTS.md
- README.md
- docs/product/PRD.md
- docs/product/PRINCIPLES.md
- docs/product/ROADMAP.md
- docs/product/MVP.md
- docs/architecture/ARCHITECTURE.md
- docs/architecture/MODULES.md
- docs/architecture/COMPATIBILITY.md
- docs/architecture/SELF_OBSERVABILITY.md
- docs/adr/*
- docs/plans/MILESTONE-001.md

Documentation must distinguish IMPLEMENTED, PLANNED and DEFERRED.
Never claim a planned feature exists.

## Milestone 1

Name: Platform Core + Self-Observability

Goal:
Create the smallest runnable vertical slice proving:
- modular architecture;
- configurable modules;
- module discovery/registry;
- health reporting;
- backend/frontend integration;
- OpenTelemetry instrumentation;
- platform self-observability;
- reproducible local startup;
- automated quality gates.

Do NOT implement production metrics storage yet.
Do NOT implement logs.
Do NOT implement distributed-trace exploration.
Do NOT implement APM.
Do NOT implement Kubernetes.
Do NOT implement AI.
Do NOT implement Datadog/Dynatrace migration.
Do NOT introduce Kafka.
Do NOT introduce microservices.
Do NOT implement dynamic JAR plugins.

## Backend

After architecture reconciliation, delegate backend implementation to the backend agent.

Use:
- Java;
- Spring Boot;
- Maven.

Create a modular monolith.

At minimum implement:
- Core module;
- Module Registry;
- Self Observability module.

Create an abstraction representing a platform module.
A module should expose enough metadata to determine:
- id;
- name;
- enabled state;
- health/status.

Configuration must allow modules to be enabled or disabled.
Future modules must be able to register without large changes to core.
Use configuration-driven compile-time modules; no runtime JAR plugin system.

Implement minimal REST endpoints:
- GET /api/platform
- GET /api/modules
- GET /api/platform/health

Use Spring Boot Actuator where appropriate rather than recreating standard health functionality.

Instrument the backend with OpenTelemetry.
The platform should emit telemetry for its own HTTP requests and JVM/runtime where practical using standard mechanisms.
Identify platform telemetry with appropriate OpenTelemetry resource attributes so it can later be separated from customer workloads.

Develop meaningful module behavior test-first.
Add ArchUnit tests for dependency direction and prohibited infrastructure/vendor dependencies.
Configure PMD, SpotBugs and Find Security Bugs in Maven so CI/build can enforce them.

## Frontend

Only after the backend API contract exists, delegate frontend implementation to the frontend agent.

Use:
- React;
- TypeScript;
- Vite.

Do not build a sophisticated dashboard yet.

Create a minimal Platform Overview page showing:
- platform status;
- installed modules;
- each module name;
- enabled/disabled state;
- module health.

Reserved navigation entries for future capabilities may be shown only if clearly unavailable/disabled.
Consume the real backend API.
Do not duplicate domain rules in React.
Keep API access isolated from UI components.
Add TypeScript typecheck, ESLint/typescript-eslint, build, and useful tests.

## OpenTelemetry

Delegate telemetry configuration to observability and deployment setup to devops in clearly separated files.

Provide an OpenTelemetry Collector configuration.
Initial flow:

Spring Boot -> OTLP -> OpenTelemetry Collector

The Collector does not need production telemetry storage in this milestone.
It must expose enough internal health/telemetry to verify that the pipeline is operating.
Prevent telemetry feedback loops.

## Local development

Target the simplest reliable workflow.
Prefer either:

`docker compose up`

or, if development is more practical outside app containers, document clearly:

`docker compose up <dependencies>`
`./mvnw spring-boot:run`
`npm run dev`

Do not introduce Kubernetes.
Never commit secrets.

## Testing

Backend minimum:
- module registration;
- enabled module behavior;
- disabled module behavior;
- health aggregation;
- relevant REST endpoints;
- architecture dependency rules.

Frontend:
- basic Platform Overview behavior where valuable;
- typecheck;
- lint;
- build.

Avoid tests that only assert framework internals.

## Implementation sequence

Phase A:
architect + product_docs + observability in parallel.

Phase B:
main agent reconciles their findings and updates the milestone plan if needed.

Phase C:
backend agent implements backend using TDD for meaningful behavior.

Phase D:
observability and devops implement telemetry/local infrastructure in separated files.

Phase E:
frontend agent implements frontend against the established backend contract.

Phase F:
run backend tests, ArchUnit, PMD, SpotBugs, FindSecBugs, frontend tests/typecheck/lint/build, and Docker/local smoke verification.

Phase G:
spawn reviewer agent in read-only mode.

Reviewer must inspect:
- correctness;
- TDD test quality;
- DDD appropriateness;
- hexagonal boundaries;
- architecture rules;
- accidental vendor coupling;
- security;
- unnecessary complexity;
- self-observability;
- documentation drift.

Wait for reviewer.
Fix every BLOCKER and HIGH finding.
Re-run the complete relevant verification suite.

## Acceptance criteria

Milestone 1 is complete when:

1. Repository builds from clean checkout.
2. Backend starts successfully.
3. Frontend starts successfully.
4. GET /api/platform works.
5. GET /api/modules reports registered modules.
6. Modules can be enabled/disabled through configuration.
7. GET /api/platform/health exposes platform/module health.
8. Frontend displays actual backend platform/module health.
9. Backend emits OpenTelemetry telemetry.
10. OpenTelemetry Collector receives it.
11. Platform telemetry is identifiable as self/platform telemetry.
12. Backend unit/integration tests pass.
13. ArchUnit architecture tests pass.
14. PMD passes.
15. SpotBugs + Find Security Bugs pass.
16. Frontend typecheck/lint/tests/build pass.
17. Local startup instructions are reproducible.
18. Documentation matches implementation.
19. Independent reviewer has no unresolved BLOCKER/HIGH findings.

## Constraints

Do not implement roadmap items merely because they are documented.
Do not create placeholder microservices.
Do not create fake vendor integrations.
Do not introduce Kafka without a measured need.
Do not introduce Kubernetes.
Do not introduce dynamic plugin loading.
Do not couple core/domain directly to Prometheus, Loki, Tempo, Datadog, Dynatrace or SigNoz.
Do not create proprietary telemetry protocols.
Prefer working software over speculative abstraction.

When uncertain, choose the smallest design preserving the four principles and the agreed architecture.

## Final report

When milestone work is complete, report:
1. architecture implemented;
2. directory tree;
3. documentation changed;
4. code created;
5. tests and quality gates executed with results;
6. how to run Geordi;
7. how to verify OpenTelemetry flow;
8. reviewer findings and fixes;
9. known limitations;
10. exact recommended scope for milestone 2.

Start now.
First inspect the repository and read AGENTS.md.
Then spawn architect, product_docs and observability in parallel.
Do not begin production implementation until their recommendations have been reconciled.

---
