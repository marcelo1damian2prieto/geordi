# Milestone 001.1 — Architecture Hardening

Status: COMPLETE

## Objective

Harden the completed Milestone 1 foundation before beginning Milestone 2 by adding
GitLab CI, removing central knowledge of optional modules, separating module inventory
from operational health evaluation, and making the Maven build version authoritative
for the artifact, API, container runtime and OpenTelemetry `service.version`.

## Findings

1. The GitLab-hosted repository has GitHub Actions but no GitLab pipeline.
2. `GeordiModulesProperties` and `ModuleConfiguration` name each optional module.
3. `ModuleRegistry.modules()` executes module health checks while building inventory.
4. The API fallback and Compose telemetry configuration duplicate the Maven version.

## Scope

- required GitLab backend, frontend, deployment-configuration and integration jobs;
- generic configuration-driven activation of Spring-discovered compile-time modules;
- deterministic inventory validation and mandatory-core enforcement;
- a dedicated, failure-isolating platform health evaluation service;
- an inventory API that does not represent unevaluated health;
- Maven build metadata propagation to the API and OpenTelemetry resource;
- behavioral, integration and architecture tests;
- synchronized architecture, API and developer documentation.

## Non-goals

- Milestone 2 capabilities;
- metrics storage or visualization;
- Prometheus, Loki, Tempo or vendor integrations;
- dynamic plugins, `ServiceLoader` or reflection-heavy discovery;
- health caching, scheduling or persistence;
- Kubernetes, authentication, multi-tenancy or unrelated refactoring.

## Reconciled architecture

`PlatformModule` describes stable module identity and its health check; activation is
deployment configuration rather than intrinsic module state. Spring discovers module
beans contributed by module-local configuration. A generic activation configuration
map defaults missing modules to enabled and is validated against discovered IDs.
`ModuleRegistry` validates and exposes ordered module inventory only.
`PlatformHealthService` creates one logical snapshot, evaluates each enabled module at
most once, skips disabled modules, isolates failures, and aggregates with deterministic
`DOWN`, `UNKNOWN`, `UP` precedence. The product health API remains representational
HTTP 200 while Actuator readiness remains operational.

Maven `project.version` is the sole application-version authority. Spring Boot build
metadata supplies the API version and the pinned OpenTelemetry Java agent derives
`service.version` from the packaged application. Compose must not override it. The
smoke test compares telemetry with the API version exactly.

## Implementation plan

1. Add failing behavior tests for generic activation, future module registration,
   inventory isolation, single-pass health evaluation and failure isolation.
2. Refactor the module contract, registry and Spring composition to satisfy them.
3. Split the inventory and health REST representations and adapt the frontend contract.
4. Remove fallback/Compose version literals and strengthen cross-boundary verification.
5. Add GitLab CI by reusing Maven, npm, Compose and the existing OTel smoke script.
6. Update ADR and architecture/API/developer documentation.
7. Run all quality gates and local container/telemetry verification.
8. Obtain independent severity-ranked review, fix required findings, and re-verify.

## Test strategy

- domain/application tests cover duplicates, ordering, defaults, disabled/core/unknown
  configuration, zero health calls during inventory, one call per enabled module per
  snapshot, disabled isolation, invalid health results, precedence and observer/check
  failure isolation;
- Spring tests cover relaxed configuration binding and module discovery without
  central optional-module edits;
- API tests cover inventory/health separation and preserved HTTP/readiness semantics;
- ArchUnit enforces dependency direction and generic composition boundaries;
- the OTel smoke test compares API and telemetry versions;
- existing frontend behavior tests and all static/build gates remain required.

## CI strategy

GitLab verify jobs use Java 21/Maven and Node 22 official images. Maven `verify` remains
the backend quality source of truth; frontend commands remain lockfile installation,
tests, typecheck, lint and build. A required tagged Linux runner performs Compose and
Collector validation, builds/starts the stack and runs the PowerShell OTel smoke test.
It must provide Docker daemon access, Compose v2 and PowerShell 7. A resource group
serializes fixed local ports. The integration job builds with `--no-cache` before
startup so a clean checkout is always rebuilt from source rather than stale local
BuildKit layers. The job is not optional or silently skipped.

## Acceptance criteria

All 25 criteria in the Milestone 1.1 request must pass, including required GitLab jobs,
future module discovery without central registry edits, inventory/health separation,
failure isolation, exact version propagation, all backend/frontend quality gates,
valid Compose/startup, successful OTel smoke verification, synchronized documentation,
and no unresolved reviewer BLOCKER or HIGH findings.

## Risks

- generic map binding requires explicit unknown-ID validation;
- removing `status` from `/api/modules` is an intentional pre-1.0 contract correction;
- raw IDE launches that bypass Maven build metadata should fail rather than invent a
  version; supported local startup remains Maven or the packaged container;
- the integration runner has privileged Docker access and fixed ports, so it must be
  trusted and serialized;
- Java-agent build metadata detection must be proved by the exact smoke assertion.

## Final verification evidence

- Backend host verification: Maven `verify` passed 23 tests with zero failures,
  including four ArchUnit rules; PMD passed; SpotBugs and Find Security Bugs reported
  zero bug instances and zero errors.
- Frontend verification after `npm ci`: two Vitest tests, TypeScript typecheck, ESLint
  and the production Vite build passed.
- Deployment configuration: `docker compose config --quiet` and Collector `validate`
  passed.
- Container verification: backend, frontend and Collector images built; the Java 21
  backend build repeated all 23 tests and static gates; all three services became
  healthy.
- API verification: inventory returned only `id`, `name`, `enabled`; health returned
  evaluated statuses. Disabling self-observability through the Compose `.env` toggle
  produced `DISABLED` while aggregate platform health remained `UP`.
- OpenTelemetry verification: 13 spans and 47 metric points were accepted/exported in
  the final run, refused/send-failed counters did not increase, Resource/JVM evidence
  was present, and telemetry `service.version` exactly matched API version
  `0.1.0-SNAPSHOT`.
- Independent review: no BLOCKER; one HIGH, three MEDIUM and one LOW. The HIGH
  startup/failure-isolation defect was fixed with a regression test. The package-wide
  ArchUnit boundary and all documentation findings were also fixed. No unresolved
  BLOCKER, HIGH or material MEDIUM findings remain.
