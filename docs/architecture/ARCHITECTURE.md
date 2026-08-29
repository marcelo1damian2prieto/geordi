# Architecture

Status: MILESTONES 1 THROUGH 11 COMPLETE; MILESTONE 12 NOT STARTED

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
the trace adapter. The active implementation is documented in `SERVICE_MAP.md`. Local
verification and independent review passed without a remaining BLOCKER or HIGH finding,
and the project owner confirmed the updated authoritative GitLab pipeline green.

## Milestones 7–8 SLO flow

```text
Read-only mounted YAML -> SLO catalog -> SLO application <- request-outcome port
                                            |                    |
                                            v                    v
React /slos <- read-only REST -- atomic SLO + burn result Metrics application
                                                                 |
                                                                 v
                                                       VictoriaMetrics adapter
```

SLOs are a real compile-time module and compose Metrics through a canonical
whole-window request-outcome boundary. Definitions and results contain only exact
service identity, closed SLI/window types, ratio targets, observations, and bounded
status/reason values. M8 enriches that same on-demand result with derived current-window
allowed/observed bad ratios and a finite burn rate when available; it adds no burn store
or separate provider query path. Provider query syntax remains in the Metrics adapter.
The catalog is version-controlled, mounted read-only, limited to 50 definitions, and
requires restart/redeployment for changes. See `SLOS.md`, ADR-014, ADR-015, and ADR-016.

## Milestone 9 Alert Evaluation flow

```text
Read-only alert-policy YAML -> alerts catalog -> Alert Evaluation <- canonical M8 burn evidence
                                                  |                         ^
                                                  v                         |
React /alert-evaluations <- read-only REST <- exact SLO/Burn composition -- SLO boundary
          |
          `-- exact identity and [from,to) --> existing /investigate
```

M9 is complete. The `alerts` logical bounded context owns policy validation and the
stateless condition comparison; it consumes canonical burn evidence through an
alerts-owned port. The SLO composition adapter is the only alert-side code that refers
to the SLO boundary. Alert domain/application code has no Metrics, VictoriaMetrics,
provider-query, persistence, notification, Service Map, Traces, or Logs dependency. It
does not recompute request outcomes, allowed bad ratio, or burn rate.

The initial condition is inclusive `BURN_RATE_ABOVE`: available canonical burn evidence
is `CONDITION_MET` when `burnRate >= threshold`, otherwise `CONDITION_NOT_MET`.
Unavailable evidence remains `UNAVAILABLE`; disabled policies are
`UNAVAILABLE/DISABLED` without SLO evaluation. These are current stateless conclusions,
not firing/resolved alert instances, delivery events, pages, or incidents.

## Milestone 10 Alert Lifecycle flow

```text
explicit POST -> canonical M9 evaluation -> pure lifecycle transition -> CAS repository
                                                        |                    |
                                                        v                    v
React /alert-evaluations <- current-state REST <- INACTIVE/FIRING <- H2 named volume
```

M10 remains inside the `alerts` bounded context. The application invokes M9 exactly
once per command, applies a provider-neutral transition function, and persists through
a repository port. H2/JDBC/Flyway and HTTP remain adapters. Current-state GET performs
no evaluation. Immutable policy/SLO/condition and evidence service/window binding,
monotonic evidence time, and optimistic compare-and-set make transitions fail closed
and idempotent in the supported single-node runtime. `UNAVAILABLE`, including disabled,
never starts or resolves. At the M10 boundary there was no scheduler, history ledger,
outbox, notification, acknowledgement, silence, or incident workflow; M11 adds only the
outbox and notification-delivery foundation described next.

M11 adds notification delivery inside the Alerts bounded context. The lifecycle
persistence adapter atomically commits a lifecycle CAS mutation and immutable outbox
row. A separate bounded worker leases due work and invokes one HTTP adapter outside the
transaction. Domain/application remain free of Spring, JDBC, HTTP, provider, and
telemetry implementation types. Alert evaluation remains command-driven.

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
    +-- Logs (implemented; Milestone 5 complete)
    +-- Traces (implemented)
    +-- Service Map (implemented; Milestone 6 complete; trace-derived, no storage)
    +-- SLOs (Milestones 7–8 complete; Metrics-derived)
    +-- Alerts (M9 evaluation, M10 lifecycle, and M11 webhook delivery complete)
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

The SLO catalog is deployment configuration rather than telemetry storage. Its YAML
adapter is replaceable behind a read-only catalog port. SLO evaluation remains stable
when the Metrics provider is replaced because the whole-window request-outcome contract
is canonical. The current-window burn calculation is derived inside that same SLO
boundary; it is not long-period error-budget accounting.

The final storage architecture is intentionally not locked in during milestone 1.
