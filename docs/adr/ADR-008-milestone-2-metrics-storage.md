# ADR-008: VictoriaMetrics Storage for the Milestone 2 Metrics Slice

Status: ACCEPTED

## Context

Milestone 2 needs one persistent, queryable metrics backend for a local OTLP vertical
slice. The choice must be operationally small and replaceable, and its types, labels
and query language must not enter Geordi domain, application or REST contracts.

Prometheus and single-node VictoriaMetrics were evaluated. Both provide mature
time-series range-query APIs. Prometheus can receive OTLP when explicitly enabled, but
its push-receiver configuration and OTel translation/resource-promotion policy add
milestone-specific decisions. Collector Prometheus remote write would additionally
require a different Collector distribution and OTel-to-Prometheus translation.

## Decision

Use one version-pinned VictoriaMetrics single-node container with a named local volume
and seven-day retention.

The existing OpenTelemetry Collector exports metrics to VictoriaMetrics through the
standard `otlphttp` exporter and VictoriaMetrics `/opentelemetry/v1/metrics` endpoint.
The store retains canonical dotted OTel metric/resource attribute names; cumulative
temporality is configured explicitly. Collector traces continue to the local debug
exporter, and metrics also retain debug export for existing smoke evidence.

The Geordi outbound adapter uses VictoriaMetrics' Prometheus-compatible read API. Only
that adapter may know MetricsQL expressions, provider endpoints, labels or JSON
envelopes. It applies strict connection/read timeouts, bounds range queries, escapes
selectors and maps responses to canonical Geordi series.

The Metrics module health probe executes a cheap valid query against the same query API.
Container health alone is insufficient. A store outage degrades Metrics/platform
readiness but does not crash the backend. Module inventory never queries the store.

The store receives both platform and monitored metrics in this local slice. Every
monitored-service/query expression requires
`geordi.telemetry.origin="monitored"`; absence is unclassified and is never treated as
workload telemetry. Collector internal metrics remain on the isolated pull endpoint and
are not fed back into its OTLP receiver.

## Consequences

- the write path remains OpenTelemetry-native and uses the current core Collector;
- local operation adds one storage container and volume, not Grafana, vmagent or a
  VictoriaMetrics cluster;
- VictoriaMetrics is replaceable by implementing another outbound adapter and changing
  deployment wiring; API, application, domain and frontend contracts remain unchanged;
- backend naming/temporality/histogram behavior requires pinned integration fixtures and
  end-to-end smoke verification;
- production authentication, HA, backups, multi-retention and remote storage are
  deliberately deferred.

