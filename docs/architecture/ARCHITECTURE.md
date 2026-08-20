# Architecture

Status: IMPLEMENTED THROUGH MILESTONE 5 LOCAL VERIFICATION / GITLAB REVALIDATION PENDING; MILESTONE 6 READY FOR GITLAB REVALIDATION

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

## Milestone 3 traces flow

```text
Demo service -- OTLP --> Collector -- OTLP/HTTP --> Tempo
                                                    ^
                                                    |
React Traces <- REST <- Traces application <- query port <- Tempo adapter
```

TraceQL, Tempo HTTP envelopes and OTLP JSON mapping remain inside the outbound adapter.
The public boundary uses exact monitored service identity, a bounded half-open time
range, canonical trace/span IDs and OpenTelemetry-aligned span semantics. See
`TRACES.md`, ADR-010 and ADR-011.

## Milestone 4 service investigation flow

```text
React /investigate -- canonical context --> Metrics public REST
                  `-----------------------> Traces public REST
```

The frontend composes the two existing bounded contexts with an exact service tuple and
one absolute range. It adds no backend aggregation boundary or domain dependency.
Signal queries remain independently observable and degradable. See
`SERVICE_INVESTIGATION.md`.

## Milestone 5 logs flow

```text
Demo service -- OTLP Logs --> Collector -- OTLP/HTTP --> Loki
                                                    ^
                                                    |
React Logs <- REST <- Logs application <- query port <- Loki adapter
```

Loki/LogQL and provider JSON stay inside the outbound adapter. The public contract uses
an exact monitored identity, bounded half-open time range, canonical severity, literal
text, and optional trace/span correlation fields. Loki label cardinality is limited by
ADR-012; see `LOGS.md`, ADR-012, and ADR-013.

## Milestone 6 Service Map flow

```text
Monitored caller -- trace context --> monitored downstream
       |                                     |
       `------------- OTLP traces -----------> Collector --> Tempo
                                                               ^
                                                               |
React /service-map <- REST <- Service Map application <- trace-evidence port
```

Service Map derives a bounded observed graph from existing trace data; it adds no
storage, cache, or provider health probe. Its vendor-neutral boundary receives only
canonical candidate trace evidence. Tempo transport, query syntax, and JSON remain in
the trace adapter. The active implementation is documented in `SERVICE_MAP.md` and
is locally verified and ready for GitLab revalidation; independent review reported no
BLOCKER or HIGH findings.

## Target logical view

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
    +-- Logs (locally verified; GitLab revalidation pending)
    +-- Traces (implemented)
    +-- Service Map (ready for GitLab revalidation; trace-derived, no storage)
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
Loki is the single Milestone 5 logs provider behind a replaceable adapter. OpenSearch or
ClickHouse require a separate future adapter and deployment decision.
Tempo is the single Milestone 3 trace provider behind a replaceable adapter. Jaeger or
other stores require a separate future adapter and deployment decision.

The final storage architecture is intentionally not locked in during milestone 1.
