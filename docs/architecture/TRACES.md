# Traces Architecture

Status: IMPLEMENTED / MILESTONE 3 COMPLETE

## Scope

The Traces bounded context provides a read-only distributed-trace investigation
slice. It does not ingest through the Geordi backend or become a generic trace/APM
explorer.

```text
Monitored service -- OTLP --> Collector -- OTLP --> Tempo
                                                 ^
                                                 |
React Traces UI <- REST <- application <- query port <- Tempo adapter
```

## Canonical identity and query semantics

Workload trace search requires the exact resource tuple:

- `geordi.telemetry.origin=monitored`;
- `service.namespace` (optional but exact; omission means canonical null/absent,
  never any namespace);
- `service.name`;
- `deployment.environment.name`.

Platform traces retain `geordi.telemetry.origin=platform`; unclassified traces and
traces with incomplete tuple fields are not workload search results. A search is
limited to a valid half-open interval `[from, to)`, maximum six hours, and 50
summaries. Results have deterministic ordering. The only optional filter is
`errorOnly`.

## Boundary

`io.geordi.traces.domain` contains provider-neutral validation/value concepts such as
trace/span IDs, service identity, time range, trace summary/detail, span status,
span kind and duration. `io.geordi.traces.application` validates canonical search
criteria, enforces query bounds, orders/maps results, and uses an outbound trace-query
port. It does not depend on Spring, OpenTelemetry SDK implementations, HTTP/JSON,
Tempo, Jaeger or TraceQL.

Inbound web code and outbound Tempo code are adapters. The adapter alone translates
Tempo API requests/responses and maps malformed/unavailable backend responses to
vendor-neutral application errors. The module configuration contributes its own
`PlatformModule`; generic bootstrap remains unaware of its concrete type.

## Data semantics

Trace detail returns complete span data available to the selected trace: valid trace,
span and parent IDs; operation; kind; service/resource identity; telemetry origin;
start timestamp; whole-nanosecond duration; status; error indication; error type; and
canonical HTTP request method, route, path, response status, server address and server
port metadata where available. The API calculates
whole-nanosecond `startOffsetNanos` relative to trace start for the waterfall. It does
not synthesize missing fields or infer error state from unrelated services.

## Health and self-observability

When enabled, Traces health executes one bounded real Tempo probe. A probe failure
reports the module down without crashing Geordi; inventory remains I/O-free.
Low-cardinality platform telemetry covers search/detail/probe counts, latency,
failures, result size and backend availability. It excludes provider query text,
selected identity and exception messages, and preserves the platform origin attribute.

## Metrics to Traces

Metrics-to-Traces is UI/context composition, not a Metrics-to-Traces domain dependency.
The Metrics view navigates using service namespace/name, environment and the
selected absolute range. The resulting `/traces` route receives no backend query
syntax and performs a normal canonical trace search.

## Replaceability

Tempo is the single Milestone 3 provider (ADR-010). Its types, HTTP API, JSON and
TraceQL remain inside its adapter. Replacing it requires a new adapter, configuration,
deployment wiring and integration tests; canonical application, REST and frontend
contracts remain unchanged (ADR-011).
