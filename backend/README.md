# Geordi backend

Single-project Java 21 / Spring Boot modular monolith for Milestone 1. Logical module
boundaries are the `core`, `selfobservability`, and `bootstrap` packages and are
enforced by ArchUnit.

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
- `GET /actuator/health/liveness`
- `GET /actuator/health/readiness`

Modules register through normal Spring composition and default to enabled. Use the
generic property form `geordi.modules.<module-id>.enabled`; for example, pass
`--geordi.modules.self-observability.enabled=false` to Maven/local startup. Compose maps
the documented `GEORDI_MODULES_SELF_OBSERVABILITY_ENABLED=false` `.env` toggle into the
generic property. Core cannot be disabled and unknown or malformed module configuration
fails startup. Module inventory never executes health checks; platform health and
Actuator readiness use the separate health service.

The API version comes from Maven-generated Spring Boot build metadata. Supported local
startup through Maven and packaged/container startup provide that metadata; startup
fails instead of inventing a fallback version when it is absent.

Console logs use Spring Boot's Logstash-compatible structured JSON format. OpenTelemetry
SDK dependencies are intentionally absent: local deployment attaches the version-pinned
OpenTelemetry Java Agent and supplies its OTLP endpoint and resource attributes.
