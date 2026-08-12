# Compatibility and Migration Architecture

Status: PLANNED

No compatibility adapter, query adapter, migration flow or telemetry fan-out is
delivered in Milestone 1. This document describes target architecture.

## Objective

Allow gradual adoption and reversible migrations.

## Compatibility targets

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

## Modes

### Overlay
Geordi consumes/queries existing telemetry infrastructure.

### Hybrid
Geordi owns some capabilities while existing systems own others.

### Full Replacement
Geordi provides the complete telemetry path and product experience.

## Architectural rule

Vendor-specific concepts must be normalized at adapters and must not leak into core domain types.

## Canonical telemetry model

OpenTelemetry semantic conventions are preferred whenever a standard concept exists.

## Migration strategy

Future migration flows should support parallel telemetry fan-out, parity validation, dashboard/alert translation where feasible, and explicit reporting for unsupported semantics.
