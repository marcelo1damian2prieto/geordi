# ADR-010: Tempo Trace Storage for the Milestone 3 Traces Slice

Status: ACCEPTED

## Context

Milestone 3 requires one persistent, queryable trace store for the local OTLP
vertical slice. The store must support service-scoped, time-bounded trace discovery
and trace-by-ID retrieval, while keeping provider query types and JSON outside
Geordi's domain, application and public API.

Grafana Tempo and Jaeger were evaluated. Both accept OpenTelemetry traces and can
support the required search and detail operations. Tempo provides a small monolithic
deployment with local filesystem storage and an HTTP API suitable for a lightweight
adapter. Jaeger also offers OTLP ingestion and a mature trace UI, but its storage and
deployment choices add more operational variation for this single-store milestone.
Neither backend's user interface is a Geordi product dependency.

## Decision

Use one version-pinned Grafana Tempo monolithic container with local filesystem
storage for Milestone 3. The existing OpenTelemetry Collector exports traces to Tempo
over OTLP. Tempo receives both platform and monitored traces, but Geordi discovery and
search must require the exact monitored resource tuple:

- `geordi.telemetry.origin=monitored`;
- `service.namespace` (optional but exact; omission means canonical null/absent,
  never any namespace);
- `service.name`;
- `deployment.environment.name`.

Missing or unclassified resource identity is never widened or treated as monitored
workload data. Geordi platform telemetry keeps
`geordi.telemetry.origin=platform` and remains excluded from workload searches.

The Tempo HTTP API, query parameters, response JSON and any TraceQL are confined to a
single outbound adapter. A bounded, vendor-neutral query port exposes service
discovery, trace-summary search and trace detail. The adapter uses explicit connect
and read timeouts. The Traces health check makes one bounded backend probe; container
health alone is not capability health.

## Consequences

- Local runtime adds Tempo and a persistent local volume, but no Grafana deployment,
  Jaeger UI, query language UI or second trace provider.
- Tempo can be replaced by a different adapter and deployment wiring without changing
  the canonical trace types, REST API or frontend contracts.
- Tempo-specific query capability does not define product scope; search is limited to
  an exact service tuple, half-open time range, optional error filter and at most 50
  summaries.
- Production HA, object storage, retention policy, authentication, multi-tenancy and
  backend migration are deferred.
