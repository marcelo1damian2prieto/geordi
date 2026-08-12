# Module Architecture

Status: IMPLEMENTED / Milestone 1

## Initial modules

### core
Mandatory platform foundation.

Responsibilities:
- platform identity;
- module registry;
- module metadata;
- health aggregation;
- configuration support.

### self-observability
Provides/coordinates Geordi's own telemetry and health visibility.

## Planned modules

- metrics
- logs
- traces
- apm
- infrastructure
- service-map
- alerts
- compatibility
- ai-rca

## Module contract

A platform module should expose, at minimum:
- id;
- name;
- enabled state;
- health/status.

`id` is stable and unique and `name` is display metadata. A compile-time module is
always registered (installed); configuration determines whether its capability is
enabled. Disabled modules remain visible, report `DISABLED`, are not health-checked,
and do not degrade platform health.

Milestone 1 statuses are `UP`, `DOWN`, `UNKNOWN` and `DISABLED`. Platform health is
`DOWN` when any enabled module is down, otherwise `UNKNOWN` when any enabled module is
unknown, and otherwise `UP`. Module results are sorted by id for deterministic APIs.

`core` is mandatory and cannot be disabled. Minimum runtime observability (Actuator,
structured operational logs and OpenTelemetry instrumentation) is a platform invariant;
disabling the `self-observability` capability does not disable that safety baseline.

Milestone 1 must not implement dynamic JAR loading. Compile-time modules activated by configuration are sufficient.

## Future dependency examples

- APM may require metrics + traces.
- Service Map requires traces.
- AI RCA may consume metrics + logs + traces.

Dependency validation should be introduced only when those dependencies become real.
