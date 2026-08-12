# ADR-002: OpenTelemetry as Canonical Telemetry Model

Status: ACCEPTED

## Context

Geordi must remain vendor-neutral and support gradual migration between observability platforms.

## Decision

Use OpenTelemetry/OTLP and OpenTelemetry semantic conventions as the canonical telemetry model wherever applicable.

## Consequences

- avoids proprietary instrumentation as the default;
- improves ecosystem compatibility;
- simplifies fan-out and migration;
- adapters are still required for vendor-specific capabilities.
- this decision does not imply customer ingestion, storage or provider adapters in
  Milestone 1.
