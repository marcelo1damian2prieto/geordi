# Local deployment

Milestone 1 runs the frontend, backend and OpenTelemetry Collector with Docker Compose.
It has no database, telemetry storage, customer-telemetry ingestion, or Kubernetes.

## Start

From the repository root:

```powershell
Copy-Item .env.example .env
docker compose up --build
```

The Compose file pins the OpenTelemetry Collector to `0.157.0` and the Java Agent to
`2.28.1`. The Java Agent download is checked against its pinned SHA-256 digest. `.env`
only contains non-secret local settings and is ignored by Git.

All published ports are loopback-only:

- backend API/readiness: `http://127.0.0.1:8080`;
- frontend: `http://127.0.0.1:3000`;
- Collector OTLP gRPC/HTTP: `127.0.0.1:4317` and `127.0.0.1:4318`;
- Collector health: `http://127.0.0.1:13133`;
- Collector internal metrics: `http://127.0.0.1:8888/metrics`.

The backend waits for the Collector health check before starting, and the frontend waits
for the backend health check. Its Java 21 runtime runs as UID `10001`, attaches the
OpenTelemetry Java Agent, exports traces and metrics over OTLP/HTTP, disables OTel logs
export, samples locally with `always_on`, and gives each process a generated
`service.instance.id`.

## Verify

```powershell
Invoke-RestMethod http://127.0.0.1:8080/api/platform
Invoke-WebRequest http://127.0.0.1:3000/
Invoke-WebRequest http://127.0.0.1:8080/actuator/health/readiness
Invoke-WebRequest http://127.0.0.1:13133/
Invoke-WebRequest http://127.0.0.1:8888/metrics
```

Generate requests to the backend and inspect the Collector debug output:

```powershell
docker compose logs --no-color otel-collector
```

Or run the automated end-to-end check:

```powershell
.\scripts\verify-otel.ps1
```
