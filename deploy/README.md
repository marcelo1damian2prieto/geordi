# Local deployment

The Milestone 7 local runtime runs the frontend, backend, two monitored demo applications, OpenTelemetry
Collector, VictoriaMetrics, Grafana Tempo, and Grafana Loki single-node storage with
Docker Compose. It has no Kubernetes or production multi-node storage cluster.

## Start

From the repository root:

```powershell
Copy-Item .env.example .env
docker compose up --build
```

The Compose file pins Grafana Tempo to `2.7.2`, Grafana Loki to `3.7.2`, the
OpenTelemetry Collector to `0.157.0`, and the Java Agent to `2.28.1`. The Java Agent
download is checked against its pinned SHA-256 digest. `.env` only contains non-secret
local settings and is ignored by Git.

All published ports are loopback-only:

- backend API/readiness: `http://127.0.0.1:8080`;
- frontend: `http://127.0.0.1:3000`;
- Collector OTLP gRPC/HTTP: `127.0.0.1:4317` and `127.0.0.1:4318`;
- Collector health: `http://127.0.0.1:13133`;
- Collector internal metrics: `http://127.0.0.1:8888/metrics`.
- VictoriaMetrics health/query API: `http://127.0.0.1:8428/health` and
  `http://127.0.0.1:8428/api/v1/query`.
- Tempo readiness/query API: `http://127.0.0.1:3200/ready` and
  `http://127.0.0.1:3200/api/search`.
- Loki readiness/query API: `http://127.0.0.1:3100/ready` and
  `http://127.0.0.1:3100/loki/api/v1/query_range`.
- monitored demo service: `http://127.0.0.1:8081`.
- monitored downstream demo service: `http://127.0.0.1:8082`.

VictoriaMetrics stores seven days of local development metric data in the named
`victoriametrics-data` volume. Tempo stores local trace WAL and blocks in the named
`tempo-data` volume. Loki stores local TSDB v13 data in the named `loki-data` volume.
All are intentionally single-node local-development topologies. The Collector waits for
the stores, sending metrics to VictoriaMetrics and traces/logs to Tempo/Loki over OTLP.
The backend waits for the Collector and stores; the frontend waits for the backend. All
three Java 21 runtimes run as UID `10001`, attach the OpenTelemetry Java Agent, export traces,
metrics, and logs over OTLP/HTTP, sample locally with `always_on`, and give each process
a generated `service.instance.id`.

Local images use neutral `:local` tags. The application version is not maintained in
Compose: Maven writes it into the backend artifact, the API reads that build metadata,
and the OpenTelemetry Java Agent derives `service.version` from the same artifact.
Compose translates the `.env` self-observability toggle into Spring's JSON property
form so the generic configuration map retains the stable hyphenated module ID.

Compose also enables the `slos` module and mounts `deploy/slos/slos.yaml` read-only at
`/etc/geordi/slos.yaml` through Spring's additional configuration location. The file is
the durable definition source for the local deployment and currently provides three
deterministic smoke definitions. The backend validates at most 50 definitions at
startup. Editing the catalog requires backend restart/redeployment; there is no runtime
CRUD or dynamic reload.

## Verify

```powershell
Invoke-RestMethod http://127.0.0.1:8080/api/platform
Invoke-WebRequest http://127.0.0.1:3000/
Invoke-WebRequest http://127.0.0.1:8080/actuator/health/readiness
Invoke-WebRequest http://127.0.0.1:13133/
Invoke-WebRequest http://127.0.0.1:8888/metrics
Invoke-WebRequest http://127.0.0.1:8428/health
Invoke-WebRequest http://127.0.0.1:3200/ready
Invoke-WebRequest http://127.0.0.1:3100/ready
Invoke-WebRequest http://127.0.0.1:8081/actuator/health/readiness
Invoke-WebRequest http://127.0.0.1:8082/actuator/health/readiness
```

Generate requests to the backend and inspect the Collector debug output:

```powershell
docker compose logs --no-color otel-collector
```

Or run the automated end-to-end check:

```powershell
.\scripts\verify-otel.ps1
.\scripts\verify-metrics.ps1
.\scripts\verify-traces.ps1
.\scripts\verify-logs.ps1
.\scripts\verify-service-map.ps1
.\scripts\verify-slos.ps1 -ExerciseProviderFailure
```

The OpenTelemetry smoke check requires the Collector's backend `service.version` to
equal the version returned by `GET /api/platform`. The metrics smoke generates demo
traffic, proves Collector metric export, verifies VictoriaMetrics persistence, and calls
the Geordi service/overview/series APIs with stored demo telemetry.

The trace smoke generates deterministic success, controlled-error and latency traffic;
the latency scenario includes an internal child span. It verifies Tempo persistence and
Geordi's exact identity/time-range trace search, trace detail, error, hierarchy and
frontend-proxy semantics.

The Logs smoke generates deterministic INFO, WARN, ERROR, and nested-span records. It
verifies Loki persistence, Geordi's exact identity/range/severity/body/correlation semantics,
Trace Search → Detail → trace/span-filtered Logs, frontend proxy behavior, and that trace/span,
request ID, and full URL metadata remain queryable without becoming Loki labels.

The Service Map smoke sends deterministic traffic from `geordi-demo-service` to
`geordi-demo-downstream-service`. It verifies the resulting direct monitored
caller-to-callee trace evidence, exact identities, bounded evidence, and the absence of
self, platform, and unrelated edges.

The SLO smoke verifies the mounted catalog, exact service/environment identities,
whole-window availability and error-rate formulas against real VictoriaMetrics evidence,
deterministic `MET`, `BREACHED`, and no-traffic `UNAVAILABLE`, provider failure,
provider-neutral REST/frontend responses, and exact Investigation navigation context.
It stops/restarts VictoriaMetrics only when `-ExerciseProviderFailure` is selected.
Milestone 7's complete local execution and independent review passed; authoritative
GitLab revalidation remains required.

## GitLab runner

The required GitLab deployment and integration jobs target a trusted Windows runner
tagged `geordi-docker-pwsh`. It must provide Docker daemon access, Docker Compose v2,
PowerShell 7, outbound access for pinned images/dependencies, and exclusive access to
the published local ports, including `8428` and `3100`. Do not remove the tag or mark
these jobs optional; a missing runner must be visible as a pending required pipeline
job. Docker daemon access is privileged, so the runner must not serve untrusted
projects.
