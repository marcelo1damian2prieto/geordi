# Self-Observability

## Principle

The observer must be observable.

## Requirements

Every Geordi runtime component should expose:
- health;
- metrics;
- traces where relevant;
- structured logs.

Platform telemetry must be distinguishable from customer telemetry, for example using OpenTelemetry resource attributes appropriate to the deployment.

## Milestone 1

The Spring Boot backend emits OpenTelemetry telemetry to an OpenTelemetry Collector.

The Collector must expose sufficient health/internal telemetry to verify that the pipeline is alive.

Milestone 1 had no production telemetry storage. Milestone 2 adds a local persistent
metrics store for the monitored-service slice while retaining the existing platform
self-telemetry verification path.

### Resource identity

Backend telemetry must include:

- `service.namespace=geordi`;
- `service.name=geordi-backend`;
- the build `service.version`;
- `deployment.environment.name=development` locally;
- `geordi.telemetry.origin=platform`;
- `geordi.platform.component=backend`;
- a unique, runtime-generated `service.instance.id`.

Maven `project.version` is the single version authority. The build produces Spring Boot
build metadata inside the application artifact. The API reads that metadata and the
pinned OpenTelemetry Java Agent derives `service.version` from the same artifact.
Compose supplies the remaining Resource attributes but does not duplicate or override
the version. Automated verification requires the API and Collector values to match.

The two `geordi.*` attributes are stable, low-cardinality classification attributes.
Absence of `geordi.telemetry.origin` means unclassified, not customer telemetry.

### Verification contract

- Actuator exposes backend liveness and readiness.
- The Collector health endpoint proves Collector readiness only.
- Collector internal counters prove accepted/exported spans and metric points.
- Collector debug output proves resource identity and expected JVM/HTTP telemetry.
- `GET /api/platform/health` reports local platform/module health and never claims
  end-to-end telemetry delivery.
- `GET /api/modules` reports inventory without running operational health checks.

### Feedback-loop prevention

Collector internal telemetry is emitted only through its internal metrics endpoint and
stderr. It is never exported to the Collector's own OTLP receiver. Milestone 1 has no
Prometheus receiver scraping that endpoint, no log receiver ingesting Collector/debug
output, and no OTLP logs pipeline. The debug exporter is terminal.

## Milestone 2 additions

The demo workload uses `geordi.telemetry.origin=monitored`, a distinct namespace/name,
deployment environment and unique instance id. Platform components retain
`geordi.telemetry.origin=platform`. Absence of origin remains unclassified. Metrics
service discovery and queries require the explicit monitored value.

Collector metrics are exported to VictoriaMetrics through OTLP/HTTP, with retry and a
bounded sending queue. Collector internal telemetry remains isolated on port 8888 and
is not routed to the Collector's own receiver, preventing a feedback loop.

Geordi records low-cardinality platform metrics for Metrics query count, duration,
failures, returned result count and backend probe outcomes. Raw provider expressions,
selected service identity and error messages are never telemetry attributes.

End-to-end verification distinguishes:

- receiver acceptance;
- exporter success, refusal, send failure and enqueue failure;
- persisted OTel series with monitored resource identity;
- Geordi service/overview/series query success.

Acceptance alone does not prove persistence or queryability.

## Milestone 3 additions

Collector traces are exported both to the local debug sink and Tempo through a bounded
retry queue. Traces searches and detail reads record low-cardinality request, duration,
failure, result-size and probe telemetry; service identity, trace IDs, TraceQL, response
bodies and exception text are never telemetry attributes.

Platform telemetry retains `geordi.telemetry.origin=platform`; monitored demo telemetry
uses `monitored`. Trace discovery/search require the exact monitored origin and composite
identity, and direct detail rejects platform-only traces. Tempo process health, the
Traces query-path probe, Collector delivery counters and successful Geordi search/detail
are separate verification facts. Collector internal telemetry remains pull-only and is
never routed back through its OTLP receiver.

## Milestone 4 additions

Service Investigation is frontend composition, so it introduces no aggregation API or
new telemetry pipeline. Its constituent Metrics and Traces calls retain existing
low-cardinality HTTP/query latency, request, failure, result-size and provider-probe
telemetry and continue to carry `geordi.telemetry.origin=platform`.

Selected service identity, absolute timestamps, trace IDs, raw MetricsQL/TraceQL, URL
query strings, response bodies and exception text are not added to custom telemetry.
Frontend page-view and UI-only section telemetry remain unavailable; adding a frontend
telemetry pipeline solely for this milestone is disproportionate.

Runtime verification found that the Java agent's backend `HttpURLConnection` client
instrumentation otherwise records provider query strings in `url.full`. The local
deployment therefore disables that one outbound auto-instrumentation. Inbound backend
HTTP traces remain enabled, while the Metrics and Traces adapters continue to expose
safe operation-only request, duration, failure, result-size and probe metrics.

## Future health indicators

- received telemetry;
- exported telemetry;
- dropped telemetry;
- exporter failures;
- queue usage;
- retry count;
- telemetry lag;
- synthetic pipeline watchdog.

## Safety

Prevent telemetry feedback loops when Geordi monitors its own pipeline.
