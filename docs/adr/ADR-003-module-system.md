# ADR-003: Configuration-Driven Compile-Time Modules First

Status: ACCEPTED

## Context

Geordi needs modular capabilities, but a dynamic plugin runtime would add substantial complexity before a proven requirement exists.

## Decision

Use compile-time modules with explicit contracts and configuration-driven activation.

Do not implement dynamic JAR loading in milestone 1.

## Consequences

- simple lifecycle and testing;
- clear module registry;
- preserves a future path toward richer plugin mechanisms if justified.
- discovery means registering compile-time definitions; it does not mean loading
  external code.

ADR-007 refines discovery as module-owned Spring composition with generic activation.
