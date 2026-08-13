# OpenTelemetry

Milestone 3 uses the version-pinned OpenTelemetry Collector image
`otel/opentelemetry-collector:0.157.0` with
[`otel-collector-config.yaml`](./otel-collector-config.yaml).
The official image currently resolves to
`sha256:4019ce4d7e7791a1a255fffb2f407af66d5017cc65543469ba565c4f47f795b8`.

The local flow keeps the Milestone 1 debug route and persists workload metrics and
traces in separate stores:

```text
geordi-backend -- OTLP/HTTP --> otel-collector -- debug exporter --> stderr
backend + geordi-demo-service -- OTLP/HTTP --> otel-collector -- OTLP/HTTP --> VictoriaMetrics
backend + geordi-demo-service -- OTLP/HTTP --> otel-collector -- OTLP/HTTP --> Tempo
```

The Collector accepts OTLP/gRPC on `4317` and OTLP/HTTP on `4318`. Its readiness
endpoint is `/` on port `13133`, and its internal Prometheus metrics are available at
`/metrics` on port `8888`. The Compose services are `backend`, `demo`,
`otel-collector`, `victoriametrics` and `tempo`.

Only traces and metrics have data pipelines. Each pipeline applies `memory_limiter`
before `batch`. Traces retain the detailed local `debug` route and are sent using
compressed OTLP/HTTP to Tempo. Metrics are debug-exported as local evidence and sent
using compressed OTLP/HTTP to VictoriaMetrics at `/opentelemetry/v1/metrics`. Both
storage exporters have bounded queues and retry policies. There is no logs pipeline.

Collector internal metrics are exposed only through port `8888`; internal JSON logs
and debug-exported payloads go only to stderr. They are not sent to OTLP. The
configuration has no scrape receiver, log receiver, or internal self-export route, so it
cannot feed its own telemetry back into its input. The Collector's `:8888` internal
metrics remain pull-only and are not persisted by VictoriaMetrics.

## Backend instrumentation contract

Compose attaches a version-pinned OpenTelemetry Java Agent to the backend and sets:

- OTLP/HTTP export for traces and metrics to `http://otel-collector:4318`;
- `OTEL_LOGS_EXPORTER=none`;
- `service.namespace=geordi` and `service.name=geordi-backend`;
- a unique runtime `service.instance.id`;
- `deployment.environment.name=development`;
- `geordi.telemetry.origin=platform` and `geordi.platform.component=backend`.

Maven `project.version` is packaged as Spring Boot build metadata. The pinned Java Agent
derives `service.version` from that metadata; Compose does not maintain a second value.

## Demo instrumentation contract

The local-only `geordi-demo-service` is a predictable monitored Spring Boot workload.
It supplies success, controlled HTTP 500, delayed and CPU-active endpoints strictly for
pipeline verification. The delayed endpoint also creates the deterministic child
`INTERNAL` span `demo.slow.work`, allowing trace hierarchy and timing to be verified.
Its Resource has `service.namespace=geordi-demo`,
`service.name=geordi-demo-service`, `deployment.environment.name=development`, and
`geordi.telemetry.origin=monitored`; it is deliberately distinct from Geordi platform
telemetry. The Java agent exports cumulative metrics and opts into stable HTTP semantic
conventions.

## Verification

After starting the local environment, run from the repository root:

```powershell
.\scripts\verify-otel.ps1
.\scripts\verify-metrics.ps1
```

The bounded smoke test checks backend readiness and Collector readiness separately,
generates backend HTTP traffic, and then verifies Collector acceptance/export counters,
failure counters, backend Resource identity, and JVM metrics in Collector debug output.
It also compares Collector `service.version` with the platform API version and exits
non-zero on any mismatch. The detailed debug exporter can expose payload data and is
therefore local-development-only.

The metrics smoke generates all demo traffic shapes, waits for Collector export and
VictoriaMetrics queries to return JVM, CPU, GC and HTTP metric data, then verifies the
Geordi metrics service, overview and series APIs. This proves persistence rather than
only Collector receipt.
