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

Production telemetry storage is deferred.

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
