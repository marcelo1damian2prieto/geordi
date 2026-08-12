# ADR-007: Self-Composed Modules and Separate Health Evaluation

Status: ACCEPTED

## Context

ADR-003 and ADR-005 established configuration-driven compile-time modules. The first
implementation still named every optional module in central Spring configuration and
evaluated operational health while producing module inventory. Both choices would make
additional modules harder to add and future external health checks unexpectedly costly.

## Decision

Use normal Spring composition to collect compile-time `PlatformModule` beans. Each
optional module contributes its own Spring configuration; generic bootstrap composition
does not import or name concrete optional modules. Activation is applied from a generic
`geordi.modules.<id>.enabled` map after discovery. Missing settings default to enabled,
unknown configured IDs fail startup, IDs are unique and ordered, and `core` remains a
mandatory centrally enforced platform invariant.

`ModuleRegistry` owns validated module inventory only. `PlatformHealthService` owns
operational evaluation. A health snapshot checks every enabled module at most once,
skips disabled modules, isolates check and observer failures, continues evaluation, and
uses deterministic `DOWN`, `UNKNOWN`, `UP` precedence.

`GET /api/modules` exposes identity and activation without a health status.
`GET /api/platform/health` exposes evaluated module and aggregate health. Product health
remains HTTP 200 when representable; Actuator readiness retains operational status codes.

## Consequences

- future compile-time modules register without central optional-module edits;
- configuration typos remain fail-fast despite generic map binding;
- inventory calls cannot trigger external dependency checks;
- module implementations and core remain free of Spring and vendor dependencies;
- the pre-1.0 inventory response intentionally drops its misleading `status` field;
- dynamic plugins, `ServiceLoader`, health caching and speculative dependency models
  remain excluded.
