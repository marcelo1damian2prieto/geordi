# Geordi backend

Single-project Java 21 / Spring Boot modular monolith. Logical module boundaries for
core, self-observability, Metrics, Traces, Logs, and Service Map are enforced by
ArchUnit.

## Verify

On Windows:

```powershell
.\mvnw.cmd verify
```

On Linux/macOS:

```bash
./mvnw verify
```

The `verify` lifecycle runs JUnit, AssertJ, ArchUnit, PMD, SpotBugs and Find Security
Bugs. Java 21 or newer is required; compilation targets Java 21 bytecode.

## Run

```powershell
.\mvnw.cmd spring-boot:run
```

The product API is exposed on port 8080:

- `GET /api/platform`
- `GET /api/modules`
- `GET /api/platform/health`
- `GET /api/logs/services`
- `GET /api/logs`
- `GET /api/service-map?environment=<exact>&from=<offset-date-time>&to=<offset-date-time>`
- `GET /actuator/health/liveness`
- `GET /actuator/health/readiness`

Modules register through normal Spring composition and default to enabled. Use the
generic property form `geordi.modules.<module-id>.enabled`; for example, pass
`--geordi.modules.self-observability.enabled=false` to Maven/local startup. Compose maps
the documented `GEORDI_MODULES_SELF_OBSERVABILITY_ENABLED=false` `.env` toggle into the
generic property. Core cannot be disabled and unknown or malformed module configuration
fails startup. Module inventory never executes health checks; platform health and
Actuator readiness use the separate health service.

Service Map defaults to enabled through `geordi.modules.service-map.enabled=true` and
requires the Traces module to be enabled. It derives a bounded observed graph from
trace evidence and does not add another provider health probe. `GET /api/service-map`
requires one exact environment and an explicit absolute range no wider than six hours.
It returns only direct monitored `CLIENT` parent -> distinct monitored `SERVER` child
relationships, with exact namespace/name/environment identities, bounded representative
trace evidence, and explicit truncation. It creates no new telemetry storage or
provider-specific public contract.

The API version comes from Maven-generated Spring Boot build metadata. Supported local
startup through Maven and packaged/container startup provide that metadata; startup
fails instead of inventing a fallback version when it is absent.

Console logs use Spring Boot's Logstash-compatible structured JSON format. OpenTelemetry
SDK dependencies are intentionally absent: local deployment attaches the version-pinned
OpenTelemetry Java Agent and supplies its OTLP endpoint and resource attributes. The
Logs module is enabled by default; `geordi.modules.logs.enabled=false` removes its
capability routes and skips its bounded Loki health probe while preserving inventory.
