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
stderr. It is never exported to the Collector's own OTLP receiver. There is no
Prometheus receiver scraping that endpoint and no log receiver ingesting Collector/debug
output. The debug exporter is terminal.

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

## Milestone 5 additions

The Collector exports OTLP Logs to Loki. Platform runtime logs retain
`geordi.telemetry.origin=platform`; workload discovery/search requires
`geordi.telemetry.origin=monitored` and the exact monitored service identity. Collector
internal logs and debug output remain terminal and are not re-ingested, preserving
feedback-loop prevention.

Logs query/probe telemetry records only low-cardinality operation, duration, outcome,
availability, and result-size information. It excludes log bodies, literal text search,
service identity, trace/span/request IDs, URLs, structured metadata, and exception text.
Loki indexes only service name, service namespace, deployment environment, and telemetry
origin; high-cardinality correlation values remain structured metadata.

## Milestone 6 additions

Service Map records low-cardinality platform telemetry for bounded query count, latency,
failure outcome, result-size buckets, and truncation. It excludes service identity,
trace/span IDs, time values, provider query text, provider payloads, and exception text.
The module reuses trace-provider health rather than adding a duplicate Tempo probe.

The local runtime adds a second monitored demo workload solely to generate propagated
service-to-service trace evidence. It remains monitored workload telemetry and is not a
Geordi platform component. Local Compose verification passed the Service Map semantic
smoke together with the existing self-observability, Metrics, Traces, and Logs smokes;
independent review reported no BLOCKER or HIGH findings, and the project owner confirmed
the updated authoritative GitLab pipeline green with the same five-smoke integration
gate.

## Milestone 7 additions

SLO evaluation records low-cardinality counters for evaluation attempts, results, and
unexpected failures plus duration. Result attributes are limited to the closed status,
SLI type, and bounded unavailable reason. The canonical Metrics request-outcome path
records request, failure, and duration without attributes.

SLO identifiers, names, descriptions, service identity, target values, timestamps,
provider expressions, provider responses, and exception text are excluded from custom
metric attributes. The SLO module checks catalog/measurement wiring and reuses Metrics
module provider health rather than issuing a duplicate VictoriaMetrics health probe.

The configured semantic smoke verifies real Metrics evidence, `MET`, `BREACHED`,
no-traffic `UNAVAILABLE`, provider failure, provider-neutral payloads, frontend proxy,
and Investigation context. It is wired into the GitLab integration job after the five
existing smokes. Full local execution and independent review passed without an
unresolved BLOCKER or HIGH finding, and the project owner confirmed the authoritative
GitLab pipeline green.

## Milestone 8 additions

The existing on-demand SLO instrumentation additionally records a low-cardinality burn
result counter. Its attributes are limited to burn availability status, closed SLI type,
and bounded burn-unavailable reason. It does not label by SLO identity/name, monitored
service identity, target, allowed/observed ratio, burn rate, timestamp, range, provider
query, response, or exception text.

The isolated burn-rate smoke verifies that this platform telemetry is persisted with only
those bounded labels. It also independently recomputes current-window burn evidence from
canonical Metrics and exercises provider failure/recovery. The smoke is placed after the
M7 SLO smoke in GitLab's integration job. M8 is **READY FOR GITLAB REVALIDATION** after
the required local verification and independent review passed without a remaining
BLOCKER or HIGH finding; this placement is not a completion claim.

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
