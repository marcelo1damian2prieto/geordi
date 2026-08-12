# ADR-001: Start as a Modular Monolith

Status: ACCEPTED

## Context

Geordi needs strong capability boundaries but the initial team/product does not justify distributed deployment complexity.

## Decision

Start as a modular monolith.

## Consequences

Positive:
- simpler development and deployment;
- easier refactoring;
- lower operational overhead;
- module boundaries can still be enforced.

Negative:
- runtime scaling is initially coarse-grained;
- care is required to prevent accidental package coupling.

## Guardrail

Use ArchUnit and package/module rules to enforce intended dependencies.
