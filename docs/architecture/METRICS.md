# Metrics Architecture

Status: IMPLEMENTED THROUGH MILESTONE 8

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
constructs the fixed overview and calls the outbound query port. Milestone 7 adds a
separate canonical request-outcome application boundary for one exact service and one
whole window; M8 reuses it to derive current-window burn evidence in SLOs. It is not a
chart-series shortcut or arbitrary metric query.

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

## Milestones 7–8 request-outcome boundary

The canonical boundary returns whole-window total HTTP request count and HTTP 5xx count
for an exact monitored identity and bounded absolute range. The SLO adapter maps its own
port to this Metrics application service; SLO domain/application code never reaches the
VictoriaMetrics adapter.

VictoriaMetrics performs one instant query at the exclusive range end and labels the
two internal result components only for response mapping. When a valid request count is
present and the same successful provider response contains no 5xx component, the
adapter returns an explicit zero error count. Missing request count remains missing;
duplicate, unknown, malformed, or non-finite components fail as invalid telemetry.
Provider transport/query failure remains distinct unavailability.

This boundary supports only request outcomes. It neither exposes MetricsQL/PromQL nor
promotes the rolling chart error-rate or p95 latency series into SLO semantics. M8 does
not add a burn-specific Metrics port, query language, storage, or provider request: the
SLO context derives allowed/observed bad ratios and burn rate from this one measurement.

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

Request-outcome count, duration, and failure telemetry uses no selected identity,
provider expression, or exception text as attributes.

Collector accepted/sent/refused/failed/enqueue-failed metric-point counters provide
pipeline evidence. Actual stored series and Geordi API results provide persistence and
query evidence; Collector acceptance alone is insufficient.

## Replaceability

VictoriaMetrics is the only Milestone 2 implementation. Replacing it requires a new
outbound adapter plus deployment wiring and adapter integration tests. Domain,
application, REST, OpenAPI and frontend contracts must remain unchanged.
