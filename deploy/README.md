# Local deployment

The Milestone 11 local runtime runs the frontend, backend, two monitored demo
applications, OpenTelemetry Collector, VictoriaMetrics, Grafana Tempo, and Grafana Loki
single-node storage, plus a deterministic webhook receiver, with Docker Compose. The
enabled SLO and Alerts modules provide deployment-managed definitions, on-demand Alert
Evaluation, explicit durable Alert Lifecycle processing, and bounded webhook delivery.
It has no Kubernetes or production multi-node storage cluster.

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
- deterministic webhook receiver fixture: `http://127.0.0.1:18080`.

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

Compose enables the `slos` and `alerts` modules. It mounts `deploy/slos/slos.yaml` read-only at
`/etc/geordi/slos.yaml` through Spring's additional configuration location. The file is
the durable definition source for the local deployment and currently provides three
deterministic smoke definitions. The backend validates at most 50 definitions at
startup. Editing the catalog requires backend restart/redeployment; there is no runtime
CRUD or dynamic reload.

The deployment also mounts `deploy/alerts/alert-policies.yaml` read-only at
`/etc/geordi/alert-policies.yaml`. Alert Lifecycle current state and the separate M11
notification outbox are stored in file-backed H2 under `/var/lib/geordi/alerts`, backed
by the named `alert-lifecycle-data` volume and versioned with Flyway. Lifecycle and
pending delivery state survive backend/container restart while that volume is retained.
Removing the volume explicitly resets both. This is a single-node local-development
persistence design; it makes no production multi-node, distributed-consensus, or
exactly-once delivery guarantee. Unavailable lifecycle/outbox storage makes Alerts and
platform readiness `DOWN`; a remote webhook failure remains a delivery outcome.

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
.\scripts\verify-slos.ps1
.\scripts\verify-burn-rate.ps1 -ExerciseProviderFailure
pwsh -File ./scripts/verify-alert-evaluation.ps1 -TimeoutSeconds 150
pwsh -File ./scripts/verify-alert-lifecycle.ps1 -TimeoutSeconds 240
pwsh -File ./scripts/verify-notification-delivery.ps1 -TimeoutSeconds 300
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
The Burn Rate smoke uses a separate monitored demo identity to establish valid zero burn
and then controlled finite-budget burn above one. It independently recomputes the
whole-window evidence from VictoriaMetrics, verifies zero-budget and no-traffic
semantics, and performs the single provider-failure/recovery exercise for the complete
SLO/Burn integration sequence.

Run the Alert Evaluation smoke after Burn Rate. It generates isolated traffic,
independently checks the exact-window canonical burn evidence and inclusive condition,
and verifies unavailable behavior, Investigation context, and bounded telemetry without
creating lifecycle state.

Run the Alert Lifecycle smoke after Alert Evaluation. It drives explicit lifecycle POST
commands and verifies current state, canonical start/resolution transitions, restart
durability, unavailable/disabled freezing, exact evidence and Investigation context,
and bounded telemetry. The M10 smoke itself does not schedule evaluation or dispatch
delivery work; the separate M11 worker consumes only committed outbox work.

Notification Delivery is enabled in the local stack with the deterministic internal
`webhook-receiver` fixture on `127.0.0.1:18080`. The backend persists delivery work in
the same named H2 volume as lifecycle state, using a separate Flyway outbox table. The
local `GEORDI_NOTIFICATION_TOKEN` fallback is test-only; production must inject a real
secret and use HTTPS. Redirects and URI credentials are rejected. Run the M11 smoke
after M10:

```powershell
pwsh -File ./scripts/verify-notification-delivery.ps1 -TimeoutSeconds 300
```

The full M10 lifecycle smoke requires a fresh lifecycle volume so prior durable state
cannot contaminate its isolated oracle. Before starting the stack for that run, stop the
project-scoped Compose stack and remove its volumes, then start a new stack. This deletes
all named local Compose data, so use it only for an intentionally disposable smoke
environment:

```powershell
docker compose down --volumes --remove-orphans
docker compose up --build -d
pwsh -File ./scripts/verify-alert-evaluation.ps1 -TimeoutSeconds 150
pwsh -File ./scripts/verify-alert-lifecycle.ps1 -TimeoutSeconds 240
pwsh -File ./scripts/verify-notification-delivery.ps1 -TimeoutSeconds 300
```

The running lifecycle smoke never removes a live volume and there is no reset endpoint.
The authoritative GitLab integration job provides the same fresh-volume prerequisite
and runs M10 after M9 and M11 after M10. On `main` at commit `f087da71`, all three
semantic smokes passed, including M11 retry/restart recovery and subsequent backend
recovery.

## GitLab runner

The required GitLab deployment and integration jobs target a trusted Windows runner
tagged `geordi-docker-pwsh`. It must provide Docker daemon access, Docker Compose v2,
PowerShell 7, outbound access for pinned images/dependencies, and exclusive access to
the published local ports, including `8428` and `3100`. Do not remove the tag or mark
these jobs optional; a missing runner must be visible as a pending required pipeline
job. Docker daemon access is privileged, so the runner must not serve untrusted
projects.
