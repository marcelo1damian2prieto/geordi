# Module Architecture

Status: MILESTONES 1 THROUGH 7 COMPLETE

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

### traces

Provides bounded service discovery, trace search and complete trace detail through a
vendor-neutral query boundary. Its module definition is always registered. Capability
beans and routes exist only when enabled; health performs one timeout-bounded Tempo
query-path probe, while inventory remains I/O-free. Traces and Metrics do not depend on
each other; cross-signal navigation is composed in the frontend with canonical context.

### logs

Provides bounded monitored-service discovery and log search through a vendor-neutral
query boundary. Its module definition is always registered. Capability beans and routes
exist only when enabled; health performs one timeout-bounded Loki read-path probe while
inventory remains I/O-free. Logs does not depend on Metrics or Traces; Service
Investigation and Trace-to-Logs are frontend composition using canonical context.

### service investigation (frontend capability)

Service Investigation is not a backend platform module. The frontend composes the public
Metrics, Traces, and Logs contracts at `/investigate`; it adds no module registration,
health check, backend aggregation service, or bounded-context dependency. Signal
activation and health remain independent.

### service-map

Provides a read-only, bounded observed-dependency capability at `/api/service-map` and
the frontend `/service-map` route. It is a compile-time module registered through its
own Spring configuration and is enabled only when both `service-map` and `traces` are
enabled. It uses canonical trace evidence through a vendor-neutral port, adds no new
provider probe, and does not depend on Metrics or Logs. Its graph is evidence-derived,
not a persistent topology catalog; see `SERVICE_MAP.md`.

### slos

Provides the read-only definition catalog, on-demand availability/error-rate evaluation,
`/api/slos` APIs, and `/slos` UI. Its compile-time module definition is always
registered. Capability beans and routes require both `slos` and `metrics` to be enabled.
The module composes only the canonical Metrics request-outcome boundary and has no
Traces, Logs, or Service Map backend dependency.

Health verifies catalog and measurement-port wiring without adding another
VictoriaMetrics probe. Metrics provider reachability remains represented by the Metrics
module, while evaluation failures become `UNAVAILABLE`. Definitions come from the
read-only mounted YAML catalog and cannot be changed through runtime APIs.

## Planned modules

- apm
- infrastructure
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
- SLOs require metrics.
- AI RCA may consume metrics + logs + traces.

Dependency validation should be introduced only when those dependencies become real.
