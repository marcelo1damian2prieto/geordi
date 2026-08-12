# Architecture

Status: IMPLEMENTED / FOUNDATION

## Initial style

Geordi starts as a modular monolith with hexagonal boundaries around external systems.

## Milestone 1 runtime flow

```text
Geordi Spring Boot backend -- OTLP --> OpenTelemetry Collector
                                      |-- debug output for local verification
                                      |-- internal metrics and health
                                      +-- no production telemetry storage
```

The Collector is external runtime infrastructure. In Milestone 1 Geordi does not
receive customer application telemetry and does not provide storage or query adapters.

## Target logical view (PLANNED)

```text
Applications
    |
    | OTLP
    v
OpenTelemetry Collector
    |
    v
Geordi Platform
    |
    +-- Core
    +-- Self Observability
    +-- Metrics (planned)
    +-- Logs (planned)
    +-- Traces (planned)
    +-- APM (planned)
    +-- Compatibility (planned)
```

This target view is not an implemented ingestion path in Milestone 1.

## Dependency rule

Domain/Application code must not depend directly on vendor APIs or infrastructure implementations.

```text
Adapters -> Application -> Domain
```

Milestone 1 uses one Spring Boot deployable and one Maven project. Logical modules are
package boundaries enforced by ArchUnit. `core` never depends on
`selfobservability`; runtime composition belongs to `bootstrap`.

## Future data providers

Metrics providers may include Prometheus, Mimir or VictoriaMetrics.
Logs providers may include Loki, OpenSearch or ClickHouse.
Trace providers may include Tempo, Jaeger or ClickHouse.

The final storage architecture is intentionally not locked in during milestone 1.
