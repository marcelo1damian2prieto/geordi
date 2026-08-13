# Architecture

Status: IMPLEMENTED / MILESTONE 2

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

## Milestone 2 metrics flow

```text
Demo Spring Boot service -- OTLP --> OpenTelemetry Collector
                                          |
                                          | OTLP/HTTP metrics
                                          v
                                    VictoriaMetrics
                                          ^
                                          |
React Metrics view <- REST <- Metrics application <- query port <- VM adapter
```

VictoriaMetrics, MetricsQL and provider JSON remain confined to the outbound adapter.
The application accepts only a composite OTel service identity, bounded time range and
closed operational-metric catalog. The backend does not participate in ingestion.

See `METRICS.md`, ADR-008 and ADR-009.

## Target logical view (PLANNED beyond Milestone 2)

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
    +-- Metrics (implemented)
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

Compile-time modules contribute `PlatformModule` beans through module-owned Spring
configuration. Generic bootstrap composition collects them, validates configuration and
builds an ordered inventory without naming optional modules. `ModuleRegistry` answers
inventory; `PlatformHealthService` separately evaluates operational health. This keeps
module listing side-effect free and leaves future provider checks behind module ports.

## Future data providers

VictoriaMetrics is the single Milestone 2 metrics provider behind a replaceable adapter.
Prometheus or Mimir may be implemented as future adapters, but are not supported now.
Logs providers may include Loki, OpenSearch or ClickHouse.
Trace providers may include Tempo, Jaeger or ClickHouse.

The final storage architecture is intentionally not locked in during milestone 1.
