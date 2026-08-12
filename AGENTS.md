# AGENTS.md

# Project

Geordi is a modular, OpenTelemetry-native observability platform.

The platform must support incremental adoption, coexistence with existing observability stacks, self-observability, and eventual replacement of vendor-specific solutions.

# Architectural principles

1. Modular by design.
2. OpenTelemetry everywhere.
3. The observer must be observable.
4. Replaceability by design.

# Architecture

Use a modular monolith initially.

Do NOT introduce microservices unless explicitly approved by an ADR.

External observability products, storage engines, protocols and vendor APIs must be accessed through ports/adapters.

Vendor-specific types must not leak into the platform core or domain model.

# Development methodology

Geordi uses pragmatic TDD, Domain-Driven Design and Hexagonal Architecture.

## TDD

Domain behavior and architectural rules should normally be developed test-first:

RED -> GREEN -> REFACTOR

Do not create trivial tests only to claim TDD compliance.

## DDD

Use domain modeling where actual business rules exist.
Maintain a shared ubiquitous language.
Do not model framework or infrastructure concepts as domain objects.
Do not introduce entities, aggregates, repositories, factories or domain services without a concrete domain reason.

## Hexagonal Architecture

External systems must be isolated behind ports/adapters.
The domain must not depend on:

- Spring
- OpenTelemetry SDK implementations
- Prometheus
- Loki
- Tempo
- Datadog
- Dynatrace
- SigNoz
- database implementations
- HTTP clients

Dependency direction must point toward the domain.

## Architecture tests

Important dependency rules must be enforced with ArchUnit.
Architectural conventions that can be automatically verified should not rely solely on documentation.

# Technology

Backend:
- Java
- Spring Boot
- Maven
- JUnit 5
- AssertJ
- ArchUnit
- PMD
- SpotBugs
- Find Security Bugs

Frontend:
- React
- TypeScript
- Vite
- React Router
- TanStack Query
- ECharts
- TanStack Table
- Zustand only when justified
- ESLint
- typescript-eslint
- Vitest
- React Testing Library

Telemetry:
- OpenTelemetry
- OTLP

Initial local deployment:
- Docker Compose

# Planned modules

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

Not all modules are implemented yet.
Never represent planned functionality as implemented.

# Compatibility targets

The architecture must allow gradual compatibility with:

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

OpenTelemetry is the canonical telemetry model.

# Self-observability

Every platform runtime component must expose:

- health;
- metrics;
- traces where relevant;
- structured logs.

Platform telemetry must be distinguishable from monitored application telemetry.

# Static analysis

Backend quality gate:
- PMD
- SpotBugs
- Find Security Bugs
- ArchUnit

Frontend quality gate:
- TypeScript type checking
- ESLint
- typescript-eslint
- tests

Static analysis runs as part of CI.
New high-severity findings fail the build.

# Engineering rules

Prefer the smallest implementation satisfying the current milestone.
Do not implement future roadmap items speculatively.
Do not introduce dependencies without a concrete requirement.
Run relevant tests after modifications.
Documentation and implementation must remain synchronized.

# Agent workflow

For substantial tasks, use specialized subagents.
Architecture and research work may run in parallel.
Avoid parallel agents modifying overlapping files.

Before implementation:
1. inspect current repository;
2. read relevant documentation;
3. produce or update the execution plan;
4. identify affected modules.

After implementation:
1. run tests;
2. run build;
3. ask reviewer agent to inspect the changes;
4. fix BLOCKER and HIGH findings;
5. update documentation;
6. summarize exactly what was implemented.

# Execution plans

For major milestones or significant architectural changes, create an ExecPlan under `docs/plans/` before implementation.

# Definition of done

A milestone is not complete merely because code compiles.
It must:

- satisfy acceptance criteria;
- have appropriate automated tests;
- build successfully;
- have reproducible startup instructions;
- expose its own health/telemetry where applicable;
- update relevant documentation;
- pass independent review.
