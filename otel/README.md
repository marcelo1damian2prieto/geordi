# OpenTelemetry

Milestone 1 uses the version-pinned OpenTelemetry Collector image
`otel/opentelemetry-collector:0.157.0` with
[`otel-collector-config.yaml`](./otel-collector-config.yaml).
The official image currently resolves to
`sha256:4019ce4d7e7791a1a255fffb2f407af66d5017cc65543469ba565c4f47f795b8`.

The local flow is deliberately small:

```text
geordi-backend -- OTLP/HTTP --> otel-collector -- debug exporter --> stderr
```

The Collector accepts OTLP/gRPC on `4317` and OTLP/HTTP on `4318`. Its readiness
endpoint is `/` on port `13133`, and its internal Prometheus metrics are available at
`/metrics` on port `8888`. The Compose service names are `backend` and
`otel-collector`.

Only traces and metrics have data pipelines. Each pipeline applies
`memory_limiter` before `batch`, then terminates at the detailed `debug` exporter.
There is no production storage and no logs pipeline.

Collector internal metrics are exposed only through port `8888`; internal JSON logs
and debug-exported payloads go only to stderr. They are not sent to OTLP. The
configuration has no scrape receiver, log receiver, or internal OTLP exporter, so it
cannot feed its own telemetry back into its input.

## Backend instrumentation contract

Compose attaches a version-pinned OpenTelemetry Java Agent to the backend and sets:

- OTLP/HTTP export for traces and metrics to `http://otel-collector:4318`;
- `OTEL_LOGS_EXPORTER=none`;
- `service.namespace=geordi` and `service.name=geordi-backend`;
- the backend build version and a unique runtime `service.instance.id`;
- `deployment.environment.name=development`;
- `geordi.telemetry.origin=platform` and `geordi.platform.component=backend`.

## Verification

After starting the local environment, run from the repository root:

```powershell
.\scripts\verify-otel.ps1
```

The bounded smoke test checks backend readiness and Collector readiness separately,
generates backend HTTP traffic, and then verifies Collector acceptance/export counters,
failure counters, backend Resource identity, and JVM metrics in Collector debug output.
It exits non-zero on failure. The detailed debug exporter can expose payload data and is
therefore local-development-only.
