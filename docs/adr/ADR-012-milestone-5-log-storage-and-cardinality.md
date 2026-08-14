# ADR-012: Loki Log Storage and Cardinality Strategy for the Milestone 5 Logs Slice

Status: ACCEPTED

## Context

Milestone 5 needs one persistent, queryable log store behind Geordi's canonical
Logs boundary. The local slice must receive OpenTelemetry Logs natively through the
Collector, retain useful trace/span correlation, and avoid an irreversible
high-cardinality index design.

Grafana Loki, ClickHouse, and OpenSearch were considered. ClickHouse and OpenSearch
can support log storage, but each adds a larger data-model and operational decision
for this bounded first provider. Loki has native OTLP ingestion, a small single-binary
local topology, and an adapter-compatible HTTP query API. Loki does not become a
Geordi product dependency: its query language and response model remain in the
outbound adapter.

## Decision

Use Grafana Loki **3.7.2** with native OTLP Logs ingestion from the OpenTelemetry
Collector. The local configuration uses TSDB schema **v13**, single-node/local storage,
and intentionally limited development retention. It is an MVP/local topology, not a
production HA or retention reference.

Set Loki `ignore_defaults: true` and index exactly these four resource attributes as
labels:

- `service.name`;
- `service.namespace`;
- `deployment.environment.name`;
- `geordi.telemetry.origin`.

All other values are structured metadata or log fields, including `trace_id`,
`span_id`, request/user/session identifiers, URLs and query strings, exception
messages, bodies, and arbitrary application attributes. The Collector and Loki
configuration must be verified so no default or accidental high-cardinality labels
are added. Trace/span IDs remain queryable as structured metadata and map to canonical
record fields; they are never promoted merely to simplify correlation.

Workload searches require `geordi.telemetry.origin=monitored` plus exact service
identity. Geordi-generated telemetry retains `geordi.telemetry.origin=platform` and
is excluded from workload results.

## Consequences

- The Logs adapter alone owns Loki HTTP, LogQL, response DTOs, structured-metadata
  syntax, provider timeouts, and malformed-response mapping.
- Replacing Loki requires another adapter and deployment wiring, not a change to the
  canonical logs model, REST API, or frontend.
- Cardinality safety is a release criterion: trace IDs, span IDs, raw URLs, and
  request IDs must be proven absent from Loki labels in the semantic smoke.
- Multiple providers, production retention/HA, tenant isolation, archive/replay, and
  advanced query capabilities are deferred.
