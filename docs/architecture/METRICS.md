# Metrics Architecture

Status: IMPLEMENTED / Milestone 2

## Scope

The Metrics bounded context provides a read-only operational view of monitored
Java/Spring Boot services. It does not ingest telemetry through the Geordi backend,
offer arbitrary metric exploration or own a generic dashboard model.

```text
Monitored service -- OTLP --> Collector -- OTLP/HTTP --> VictoriaMetrics
                                                              ^
                                                              |
React UI <- Metrics REST <- application service <- query port <- adapter
```

## Boundary

`io.geordi.metrics.domain` contains only validated value types for service identity,
time ranges, supported operational metrics, units, points and series.

`io.geordi.metrics.application` validates requests, selects bounded resolution,
constructs the fixed overview and calls the outbound query port.

Inbound web and outbound VictoriaMetrics code are adapters. Spring composition,
provider properties, HTTP clients, JSON envelopes, MetricsQL expressions and explicit
OpenTelemetry query instrumentation remain outside domain/application code.

Dependencies point inward:

```text
web / Spring / VictoriaMetrics adapters -> application -> domain
Metrics platform-module integration -> public core module contract
```

There is no metric repository or backend write port. Collector-to-storage ingestion is
deployment infrastructure.

## Canonical service identity

A monitored service is selected by the composite resource identity:

- `service.name` (required);
- `service.namespace` (optional in the general contract, explicit for the demo);
- `deployment.environment.name` (required by the Milestone 2 product contract).

`service.instance.id` identifies a runtime instance but is aggregated away in this
service-level view. Only telemetry explicitly marked
`geordi.telemetry.origin=monitored` is discoverable; missing origin is unclassified.

## Fixed metric catalog

The public catalog is intentionally closed:

- JVM memory used;
- JVM CPU utilization;
- JVM thread count;
- JVM GC duration;
- HTTP request rate and count;
- HTTP request p95 latency;
- HTTP error rate and count.

The adapter maps this catalog to pinned OpenTelemetry instrument names and stored
representations. It owns rate/counter reset behavior, histogram quantiles and provider
query expressions. Clients cannot control metric names, dimensions, aggregation,
resolution or query language.

## Activation and health

The Metrics platform-module definition is always registered, so disabled capability
remains visible in inventory. Backend/query/application/controller beans exist only
while `geordi.modules.metrics.enabled` is true. Disabled routes are absent and health
does not query storage.

Enabled Metrics health runs a cheap, timeout-bounded query through the backend probe.
Failure reports Metrics/platform readiness down without crashing the runtime.
`GET /api/modules` remains storage-I/O-free.

## Self-observability

Metrics query request count, duration, errors, returned point count and backend probe
availability are platform telemetry. Attributes are bounded and never contain provider
query text, error messages or selected service identity. Existing HTTP client/server
agent instrumentation supplies traces where applicable.

Collector accepted/sent/refused/failed/enqueue-failed metric-point counters provide
pipeline evidence. Actual stored series and Geordi API results provide persistence and
query evidence; Collector acceptance alone is insufficient.

## Replaceability

VictoriaMetrics is the only Milestone 2 implementation. Replacing it requires a new
outbound adapter plus deployment wiring and adapter integration tests. Domain,
application, REST, OpenAPI and frontend contracts must remain unchanged.
