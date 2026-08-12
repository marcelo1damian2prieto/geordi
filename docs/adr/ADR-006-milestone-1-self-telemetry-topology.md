# ADR-006: Milestone 1 Self-Telemetry Topology

Status: ACCEPTED

## Context

Milestone 1 must prove that Geordi emits identifiable platform telemetry and that a
local OpenTelemetry Collector receives it, without adding production storage or
creating telemetry feedback loops.

## Decision

Instrument the Spring Boot process with a version-pinned OpenTelemetry Java Agent.
Export traces and JVM/HTTP metrics via OTLP/HTTP to a version-pinned Collector. Keep
instrumentation in bootstrap/deployment rather than core code.

The backend Resource uses standard service and deployment attributes plus
`geordi.telemetry.origin=platform` and `geordi.platform.component=backend`.
`service.instance.id` is unique per runtime instance.

Maven `project.version` is the application-version authority. Spring Boot packages it
as build metadata for the platform API and the OpenTelemetry Java Agent derives
`service.version` from the same packaged metadata. Deployment configuration must not
override it with a separately maintained value. The smoke verification compares the
API and telemetry values exactly.

The Collector exposes a health endpoint and internal metrics and sends received traces
and metrics to a local-only debug exporter. Its own internal telemetry is never routed
to its OTLP receiver. There is no logs pipeline, production store, customer telemetry
ingestion or provider integration in Milestone 1.

## Consequences

- HTTP/JVM telemetry is available without SDK coupling in core;
- health, acceptance and export are verified as separate facts;
- detailed debug output is local-development-only;
- loop isolation is enforced by topology rather than classification filters.
