# ADR-013: Canonical Logs Query Boundary

Status: ACCEPTED

## Context

Milestone 5 must let operators inspect relevant records and correlate a trace without
teaching them Loki or exposing LogQL. Provider query objects, stream selectors, and
raw responses would violate replaceability and make the initial slice an unbounded log
console.

## Decision

The Logs application exposes a query-only outbound port with operations equivalent to:

- `listLogServices(range)`;
- `searchLogs(criteria)`;
- `probeLogs()`.

`searchLogs` accepts only canonical service identity, an ordered half-open range
`[from, to)`, optional severity, optional literal text, optional trace ID, optional
span ID, and a bounded limit. Service name and environment are required. Namespace is
optional, but omission means the canonical null/absent namespace only, never a
wildcard. The maximum range is six hours; the default limit is 100 and the maximum is
200. Text is a literal substring of at most 256 characters, not a regular expression
or a query language. A span ID requires a trace ID.

Results are deterministically newest-first. A canonical record contains timestamp,
optional observed timestamp, severity, optional severity text, body, service identity,
trace/span IDs when present, and a flat string attributes map. Severity is mapped from
OpenTelemetry numeric severity groups to exactly `UNSPECIFIED`, `TRACE`, `DEBUG`,
`INFO`, `WARN`, `ERROR`, and `FATAL`.

REST accepts no LogQL, Loki labels/selectors, arbitrary attributes, cursor, pagination
tokens, regex, or boolean query syntax. `GET /api/logs/services` and `GET /api/logs`
return only vendor-neutral contracts. Empty results are valid evidence; invalid input,
disabled capability, unavailable provider, malformed provider response, and timeout
remain distinct outcomes.

Trace-to-Logs navigation is UI/application composition. It is available only when
Trace Detail carries a valid canonical service/environment/range context and a valid
trace ID; an optional span ID refines that same canonical query. Neither Logs nor
Traces domain code depends on the other.

## Consequences

- Frontend and public APIs stay independent of Loki and can remain stable if storage
  changes.
- The bounded contract deliberately excludes an IDE-like console, arbitrary LogQL,
  saved searches, and pagination infrastructure.
- Architecture tests must prohibit Spring, HTTP/JSON, Loki, and LogQL dependencies in
  Logs domain/application packages and prohibit Logs--Traces/Metrics domain cycles.
