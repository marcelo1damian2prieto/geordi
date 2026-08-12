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

Modules default to enabled. The optional self-observability capability can be disabled
with `GEORDI_MODULES_SELF_OBSERVABILITY_ENABLED=false`. Core cannot be disabled and
unknown or malformed module configuration fails startup.

Console logs use Spring Boot's Logstash-compatible structured JSON format. OpenTelemetry
SDK dependencies are intentionally absent: local deployment attaches the version-pinned
OpenTelemetry Java Agent and supplies its OTLP endpoint and resource attributes.
