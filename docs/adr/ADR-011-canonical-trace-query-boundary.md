# ADR-011: Canonical Trace Query Boundary

Status: ACCEPTED

## Context

Milestone 3 needs a useful trace investigation flow without exposing the selected
storage backend. Directly accepting TraceQL, Jaeger parameters, arbitrary attribute
filters or backend response objects would couple Geordi's public product contract to
the first provider and turn the slice into a generic trace explorer.

Trace data is also unsafe to group by service name alone. The same name may occur in
different namespaces or environments.

## Decision

The Traces application exposes a query-only outbound port with operations equivalent
to:

- `listTraceServices(range)`;
- `searchTraces(criteria)`;
- `getTrace(traceId)`.

The canonical investigation context is the monitored resource tuple:
`service.namespace`, `service.name`, and `deployment.environment.name`, together
with `geordi.telemetry.origin=monitored`. Service name and environment are required.
Namespace is optional, but omission means an exact canonical null/absent namespace;
it never broadens a query. A missing environment never broadens a query.

`TimeRange` is a valid, ordered half-open interval `[from, to)`, with a maximum span
of six hours. Search returns at most 50 deterministic trace summaries. `errorOnly`
is the sole optional search filter. Trace identifiers and span identifiers are
validated opaque hexadecimal identifiers; IDs, timestamps and parent relationships
are never fabricated.

Canonical trace summaries contain the trace ID, root operation, start time, duration in
whole nanoseconds, span count and error indicator. The searched service identity is
returned once as search context. Trace detail
contains the complete returned span set: trace/span/parent IDs, operation, kind, start
time, duration in whole nanoseconds, status, resource service identity, telemetry
origin, error indication/error type, and canonical HTTP metadata when available. The
HTTP shape is limited to request method, route, path, response status, server address
and server port. Span offsets in API/UI are whole nanoseconds relative to the trace
start. The application validates stable ordering and parent-child relationships; the
provider adapter owns provider-specific mapping and malformed-response handling.

REST accepts only canonical IDs, tuple fields, ISO-8601 bounds and `errorOnly`; it
does not accept TraceQL, arbitrary attributes, service-instance selectors, pagination
tokens or provider-specific filter/query terms.

## Consequences

- Storage replacement does not require changes to the domain/application, REST or UI
  contract.
- This boundary is intentionally insufficient for arbitrary trace querying, saved
  searches, service maps and APM-style analysis; those are deferred.
- Missing telemetry yields an empty list, while invalid requests, missing trace IDs and
  unavailable storage are distinct vendor-neutral outcomes.
- Architecture tests must prohibit Spring, HTTP clients, JSON, OpenTelemetry SDKs,
  Tempo, Jaeger and TraceQL from traces domain/application packages.
