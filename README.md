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

## Milestone 1 — implemented

**Platform Core + Self-Observability**

The first milestone proves:
- modular architecture;
- module registry;
- enable/disable configuration;
- platform/module health;
- backend/frontend integration;
- OpenTelemetry instrumentation;
- Collector reception;
- reproducible local startup.

It intentionally does **not** implement metrics storage, logs, trace exploration, APM, Kubernetes, AI or vendor migrations yet.

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
and proves that spans and JVM metrics are accepted and debug-exported without refused
or failed telemetry.

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

## Documentation

See:
- `docs/product/`
- `docs/architecture/`
- `docs/adr/`
- `docs/plans/`
