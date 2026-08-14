# Logs Architecture

Status: IMPLEMENTED THROUGH MILESTONE 5 LOCAL VERIFICATION / GITLAB REVALIDATION PENDING

## Scope

The Logs bounded context is a read-only, bounded operational evidence slice. It ingests
OpenTelemetry Logs through the Collector into Loki and exposes a vendor-neutral
service-scoped search API and `/logs` experience.

```text
Monitored workload -- OTLP Logs --> Collector -- OTLP --> Loki
                                                        ^
                                                        |
React Logs UI <- REST <- application <- query port <- Loki adapter
```

It is not an arbitrary log console, a LogQL editor, a log pipeline manager, or a
cross-signal backend aggregation service.

## Canonical semantics

Workload queries require the exact tuple `service.namespace` (optional but exact),
`service.name`, `deployment.environment.name`, and
`geordi.telemetry.origin=monitored`. Omitted namespace matches canonical absence only.
Platform telemetry is marked `geordi.telemetry.origin=platform` and remains distinct.

Search uses `[from, to)`, no more than six hours, a default limit of 100, and a maximum
limit of 200. Results are deterministic newest-first. Optional filters are one
canonical severity, literal substring text (at most 256 characters), trace ID, and
span ID; span ID requires trace ID.

Each record returns its event timestamp, observed timestamp when available, canonical
severity and severity text, body, service identity, trace/span IDs when available, and
a flat string attributes map. OpenTelemetry numeric severities map by group to
`UNSPECIFIED`, `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, or `FATAL`. Missing records
and a zero-record ERROR subset are normal empty results, not backend failures.

## Loki isolation and cardinality

Loki 3.7.2, native OTLP ingestion, and TSDB v13 are implementation decisions recorded
in ADR-012. With Loki defaults ignored, exactly four index labels are permitted:
`service.name`, `service.namespace`, `deployment.environment.name`, and
`geordi.telemetry.origin`. All other OTel resource/log attributes and correlation data
are structured metadata/log fields. In particular trace IDs, span IDs, request IDs,
URLs, bodies, and exception messages are never labels.

The Loki adapter owns every Loki/LogQL type, selector, metadata query, HTTP request,
JSON DTO, timeout, and provider-error translation. Domain/application, REST, and UI
know only the canonical contract in ADR-013.

## Investigation and trace correlation

Service Investigation remains frontend composition. Its Logs section consumes the
same canonical namespace/service/environment/absolute-range context as Metrics and
Traces and fails independently. It can show recent bounded records and link to the
full Logs route without changing context.

Trace Detail exposes “View related logs” only with valid carried canonical context and
a valid trace ID. The Logs route receives canonical fields, `traceId`, and optional
`spanId`; it never receives LogQL or a provider-specific expression. No Logs--Traces
domain dependency is introduced.

## Failure, health, and self-observability

Loading, valid empty results, provider unavailable, malformed provider responses,
timeouts, invalid requests, and disabled-module routes are distinct UI/API states.
A Logs failure does not hide Metrics or Traces, and failures in those signals do not
hide valid Logs.

When enabled, Logs health runs one bounded real Loki/read-path probe. A failure reports
the module down without crashing Geordi or making module inventory perform I/O. Low
cardinality platform telemetry records query/probe counts, latency, failure outcome,
availability, and result-size buckets. It excludes bodies, text search, IDs, service
identity, and exception text.
