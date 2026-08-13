# ADR-009: Canonical Metrics Query Boundary

Status: ACCEPTED

## Context

The first product use case is a fixed operational view of one monitored Spring Boot
service. Accepting arbitrary metric names, dimensions, aggregation or provider query
text would couple public contracts to the first store and prematurely create a generic
metrics explorer.

Service name alone is also not a safe identity because the same name may exist in
several namespaces or environments.

## Decision

The Metrics application exposes a query-only port using pure Geordi types:

- `ServiceIdentity`: `service.name`, optional `service.namespace`, and
  `deployment.environment.name`;
- `TimeRange`: ordered, bounded instants;
- a closed `OperationalMetric` catalog;
- a server-selected resolution bounded to a maximum response size;
- immutable `MetricSeries` and ordered `MetricPoint` values with canonical units.

The Milestone 2 catalog covers JVM memory, CPU utilization, threads, GC duration, HTTP
request rate/count, p95 latency and error rate/count. Each has one fixed aggregation
semantic. CPU time may be exposed separately or used by the adapter to derive
utilization; it is never silently returned as a utilization ratio.

The application owns validation, point bounds, deterministic ordering and overview
composition. The outbound adapter owns stored OTel name mapping, label normalization,
counter reset/rate handling, histogram quantiles, backend expressions and response
parsing. Valid absence produces empty data; backend/query failure is a distinct
vendor-neutral error.

REST exposes service discovery, overview and batched supported-series operations using
the composite identity and ISO-8601 bounds. It never accepts raw provider expressions,
arbitrary label filters, group-by or aggregation. Resolution is not client-controlled.

Metrics ingestion does not pass through the Geordi backend, so no write repository,
metric aggregate or persistence domain service is introduced.

## Consequences

- storage replacement cannot require REST/frontend/domain changes;
- the contract is intentionally opinionated and cannot power a generic explorer;
- OTel semantic-convention and storage mapping changes are localized to adapter tests;
- service-instance drilldown and arbitrary dimensions are deferred;
- architecture tests must keep metrics domain/application independent of Spring,
  OpenTelemetry SDKs, HTTP clients, persistence, VictoriaMetrics and query languages.

