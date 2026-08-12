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

## Milestone 1 / 1.1 — implemented

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
proves that spans and JVM metrics are accepted and debug-exported without refused or
failed telemetry, and requires telemetry `service.version` to match the platform API.

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

GitHub Actions and GitLab CI run the same commands. GitLab's required deployment and
stack-smoke jobs use a trusted Linux runner tagged `geordi-docker-pwsh` with Docker
daemon access, Docker Compose v2, PowerShell 7, outbound image access, and the fixed
local ports available. The integration job is serialized by a resource group.

## Documentation

See:
- `docs/product/`
- `docs/architecture/`
- `docs/adr/`
- `docs/plans/`
