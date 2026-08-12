# ADR-004: Self-Observability Is a First-Class Requirement

Status: ACCEPTED

## Context

A monitoring platform that cannot prove the health of its own telemetry pipeline can produce dangerous false confidence.

## Decision

Geordi will instrument its own runtime using OpenTelemetry and expose platform/module health.

## Consequences

- telemetry pipeline health becomes visible;
- Geordi validates its own observability capabilities continuously;
- feedback loops must be explicitly prevented.
- Milestone 1 verifies transport to the Collector, not end-user telemetry storage,
  query or visualization.
