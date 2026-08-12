# ADR-005: Milestone 1 Module Boundaries and Activation

Status: ACCEPTED

## Context

Milestone 1 must prove modularity and configuration-driven activation without adding
distributed deployment, dynamic plugins or build complexity. It must also distinguish
installed modules from enabled capabilities and from the runtime observability baseline.

## Decision

Use one Maven project and one Spring Boot deployable. Represent logical modules with
Java package boundaries enforced by ArchUnit.

- `bootstrap` composes the runtime;
- `core` owns the pure module contract, registry and health aggregation;
- `selfobservability` may depend only on the public core module contract;
- `core` never depends on `selfobservability`;
- domain, application and module-contract packages do not depend on Spring,
  OpenTelemetry implementations, HTTP clients, persistence or vendor APIs.

All compile-time module definitions are registered. Configuration controls their
enabled capability state. Disabled modules remain visible, report `DISABLED`, are not
health-checked and do not degrade platform health. `core` is mandatory and cannot be
disabled. Minimum runtime instrumentation, operational health and structured logging
remain active regardless of optional capability switches.

## Consequences

- modular boundaries are testable without a multi-module build;
- API responses can distinguish installed and enabled modules;
- future modules can register through the same contract;
- runtime JAR loading, repositories and speculative domain abstractions are excluded.

ADR-007 refines this decision by removing central optional-module knowledge and by
separating registered inventory from operational health evaluation.
