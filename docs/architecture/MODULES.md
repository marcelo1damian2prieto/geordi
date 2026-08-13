# Module Architecture

Status: IMPLEMENTED / MILESTONE 2

## Initial modules

### core
Mandatory platform foundation.

Responsibilities:
- platform identity;
- module registry;
- module metadata;
- activation validation;
- platform health evaluation.

### self-observability
Provides/coordinates Geordi's own telemetry and health visibility.

### metrics

Provides the read-only, fixed operational metrics capability. Its module definition is
always registered through module-owned Spring configuration. When disabled, storage,
application and REST capability beans are absent, health is skipped, and inventory
still reports the installed module as disabled.

When enabled, health performs a timeout-bounded real query through the outbound backend
probe. `/api/modules` remains independent and performs no storage I/O. Metrics depends
on the public core module contract; core and bootstrap do not know the concrete module.

## Planned modules

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
- health check.

`id` is stable and unique and `name` is display metadata. Optional modules contribute
their own Spring configuration and `PlatformModule` bean. Generic bootstrap composition
collects those beans without knowing concrete optional module types. A compile-time
module is always registered (installed); the generic `geordi.modules.<id>.enabled`
configuration map determines whether its capability is enabled. Missing settings default
to enabled. Unknown configured IDs, duplicate discovered IDs, and a missing or disabled
`core` module fail startup.

`ModuleRegistry` exposes deterministic inventory (`id`, `name`, `enabled`) and never
executes health checks. `PlatformHealthService` creates operational snapshots. Disabled
modules report `DISABLED` only in health output, are not health-checked, and do not
degrade platform health. Each enabled check runs once per snapshot and a failing check
cannot prevent the remaining modules from being evaluated.

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
