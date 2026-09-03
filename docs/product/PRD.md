# Geordi Product Requirements Document

Status: MILESTONES 1 THROUGH 13 COMPLETE

## Vision

Geordi is a modular, OpenTelemetry-native observability platform that helps organizations understand distributed systems while preserving interoperability and minimizing vendor lock-in.

## Problem

Organizations commonly face one or more of these problems:
- fragmented metrics, logs and traces;
- expensive or inflexible SaaS observability platforms;
- operational complexity in open-source stacks;
- vendor-specific instrumentation and query models;
- disruptive migrations between observability products;
- poor visibility into the observability platform itself.

## Product proposition

Geordi combines:
- a unified observability experience;
- modular deployment;
- open telemetry standards;
- compatibility with existing systems;
- self-observability;
- gradual migration paths.

## Core principles

1. Modular by Design.
2. OpenTelemetry Everywhere.
3. The Observer Must Be Observable.
4. Replaceability by Design.

## Deployment modes

### Overlay
Geordi provides a unified experience over existing observability infrastructure.

### Hybrid
Some signals/providers are owned by Geordi and others remain external.

### Full Replacement
Geordi owns the complete telemetry path and user experience.

## Capabilities

- core platform;
- metrics;
- logs;
- traces;
- APM;
- infrastructure monitoring;
- service map;
- service-level objectives;
- alerts;
- compatibility/migration;
- self-observability;
- future AI-assisted incident analysis.

## Milestone 1 scope

Status: COMPLETE

Milestone 1 provides:
- platform core;
- module abstraction/registry;
- enable/disable configuration;
- platform/module health;
- backend API;
- minimal frontend overview;
- OpenTelemetry self-instrumentation;
- local OpenTelemetry Collector.

Milestone 1 does not ingest, persist, query or present customer telemetry. Collector
reception is verified only for Geordi platform telemetry.

DEFERRED:
- telemetry storage;
- metrics explorer;
- logs explorer;
- trace explorer;
- APM;
- service map;
- alert evaluation;
- Kubernetes;
- AI;
- vendor-specific migration adapters.

## Milestone 2 scope

Status: COMPLETE

Milestone 2 adds the first monitored-workload telemetry path. A sample Spring Boot
service emits OpenTelemetry JVM and HTTP metrics through the Collector to one persistent
store. Geordi lists monitored services and returns a fixed operational overview and
bounded series through a vendor-neutral query boundary. React presents the same fixed
concepts with service/range selection and explicit loading, empty and failure states.

Milestone 2 does not provide arbitrary metric queries, editable/saved dashboards, APM,
logs, traces, correlation, service maps, alerts, SLOs, tenancy, Kubernetes, AI or
provider migration.

## Milestone 3 scope

Status: COMPLETE

Milestone 3 adds persistent distributed traces through Tempo behind a vendor-neutral
query port. Operators can discover and search an exact monitored service identity in a
bounded time range, inspect complete span hierarchy/timing/error data, and move from
Metrics to Traces with the same canonical context.

Milestone 3 does not add logs, full APM, service maps, alerting, arbitrary TraceQL,
saved searches, multiple trace stores, tenancy, Kubernetes, AI or Milestone 4 work.

## Milestone 4 scope

Status: COMPLETE

Milestone 4 composes the existing Metrics and Traces capabilities into one fixed,
service-centric `/investigate` workflow. Operators carry an exact namespace/name/
environment identity and one absolute range across RED metrics, JVM/resource signals,
recent traces, error traces, duration-ordered recent traces, and existing Trace Detail.
Missing telemetry, valid zero, empty results, provider failures, and stale context
transitions remain distinct.

Composition is frontend-only. Milestone 4 does not add Logs, backend aggregation, full
APM, dashboards/widgets, service maps, alerts/SLOs, anomaly detection, new providers,
infrastructure product features, arbitrary query languages, or Milestone 5 work.

The project owner confirmed the authoritative GitLab pipeline for Milestone 4 is green.

## Milestone 5 scope

Status: COMPLETE

Milestone 5 adds the bounded Logs vertical slice: a demo workload emits OTLP Logs to
the Collector and Loki; Geordi queries Loki through a vendor-neutral port/adapter and
serves `/api/logs/services`, `/api/logs`, and `/logs`. Operators use one exact monitored
service identity and absolute range, filter with canonical severity or literal text,
and inspect record body, attributes, and available trace/span correlation.

Service Investigation composes Logs independently with Metrics and Traces. Trace Detail
opens related Logs only with valid carried identity/range context and trace correlation.
No LogQL reaches the public API or UI. Loki labels are limited to low-cardinality
service/environment/origin fields; correlation IDs and arbitrary fields remain
structured metadata.

Milestone 5 does not add service maps, alerts, dashboards, saved searches, arbitrary
query languages, multiple providers, advanced retention, multi-tenancy, Kubernetes,
APM, or AI/RCA. Local acceptance criteria and independent review passed without a
remaining BLOCKER or HIGH finding. The project owner subsequently confirmed the
authoritative GitLab pipeline green; its integration gate includes Logs semantic
verification.

## Milestone 6 scope

Status: COMPLETE

Milestone 6 adds a bounded Service Map derived only from available monitored traces.
For one exact environment and explicit absolute `[from,to)` range of at most six hours,
an edge means a monitored `CLIENT` span is the direct parent of a monitored `SERVER`
span in a distinct exact namespace/name/environment identity, and the SERVER start is
inside the selected range. The map exposes endpoint nodes, directed deduplicated edges,
distinct-trace evidence counts, up to three representative trace references, and an
explicit truncation flag through `/api/service-map` and `/service-map`.

It is observed evidence, not configured, static, complete, infrastructure, network, or
CMDB topology. Missing edges do not prove that a dependency does not exist. Candidate
and detail retrieval, graph size, and representative evidence are explicitly bounded;
the local Compose runtime adds one deterministic monitored downstream workload and a
focused Service Map smoke for semantic verification. Node navigation reuses Service
Investigation; edge evidence reuses existing Trace Detail.

Milestone 6 does not add a telemetry store, graph database, cache, Logs/Metrics-derived
relationships, async inference, external dependency nodes, edge performance analytics,
alerts/SLOs, generic graph/query engines, or Milestone 7 work. Local backend/frontend
quality gates, Compose build, all five semantic smokes, and independent review passed
with 0 remaining BLOCKER findings and 0 remaining HIGH findings. The Service Map smoke
is part of the authoritative integration gate, and the project owner confirmed the
updated authoritative GitLab pipeline green.

## Milestone 7 scope

Status: COMPLETE

Milestone 7 adds a bounded SLO module over the existing canonical Metrics capability.
The deployment supplies at most 50 definitions through a version-controlled YAML file
mounted read-only into the backend. Operators can list and inspect definitions through
`GET /api/slos` and `GET /api/slos/{id}`, request an on-demand evaluation through
`GET /api/slos/{id}/evaluation`, and inspect results at `/slos`. Definition changes
require restart/redeployment; runtime create, update, and delete are not supported.

The supported SLIs are availability `(N-E)/N`, met when the observed ratio is greater
than or equal to the target, and error rate `E/N`, met when it is less than or equal to
the target. `N` is whole-window request count and `E` whole-window HTTP 5xx count for
one exact monitored namespace/name/environment identity. Targets are ratios in `[0,1]`,
equality is met, and windows are exactly `PT5M`, `PT15M`, `PT1H`, and `PT6H`.

Results expose target, observed ratio when valid, request count, absolute range,
evaluation time, and `MET`, `BREACHED`, or `UNAVAILABLE`. Bounded unavailable reasons
distinguish disabled definitions, no traffic, missing request/error counts, invalid
telemetry, and Metrics unavailability. The UI preserves the returned identity and range
when navigating to Service Investigation. PromQL/MetricsQL and VictoriaMetrics response
types remain confined to the Metrics adapter.

Milestone 7 does not add latency SLOs, arbitrary expressions, runtime CRUD, scheduling,
evaluation history, long-window compliance accounting, error budgets, notifications,
alert lifecycle, incident management, new telemetry storage, or Milestone 8 work. Its
backend/frontend quality gates, deployment/configuration verification, semantic SLO
smoke, Milestones 1 through 6 regression smokes, and independent review passed without
an unresolved BLOCKER or HIGH finding. The semantic SLO smoke is part of the
authoritative GitLab integration gate, and the project owner subsequently confirmed
that pipeline green.

## Milestone 8 scope

Status: COMPLETE

Milestone 8 enriches the existing on-demand SLO evaluation response and `/slos` view
with one atomic configured-window error-budget burn snapshot. It derives allowed bad
ratio from canonical SLI semantics: availability uses `1 - target`; error rate uses
`target`. With valid whole-window evidence (`N > 0` and `0 <= E <= N`), observed bad
ratio is `E/N` and burn rate is the dimensionless
`observedBadRatio / allowedBadRatio`. The API retains ratio semantics; percentages are
presentation formatting only.

Burn evidence is `AVAILABLE` only for valid evidence with a positive allowed bad ratio.
It is `UNAVAILABLE` with bounded reasons for disabled definitions, no traffic, missing
counts, invalid telemetry, Metrics unavailability, or a zero allowed bad ratio. A zero
allowed bad ratio retains a valid observed bad ratio but has no numeric burn rate; NaN
and infinity never represent a perfect-target result. The snapshot uses the same exact
canonical identity and returned absolute window for SLO evaluation and Investigation
navigation.

M8 adds neither remaining-budget claims nor long-period compliance accounting,
persistence, history, scheduling, alert rules or lifecycle, notifications, on-call
routing, incidents, arbitrary queries, or new providers. A deterministic isolated
burn-rate smoke and GitLab placement are implemented. Required local verification and
independent review passed without a remaining BLOCKER or HIGH finding. The authoritative
GitLab pipeline passed the complete preceding milestone smoke chain and the Burn Rate
smoke with provider-failure exercise enabled. It validated `AVAILABILITY` and
`ERROR_RATE` objectives, `allowedBadRatio`, `observedBadRatio`, `burnRate`, valid-zero
and elevated burn behavior, no-data/unavailable semantics, provider failure and recovery,
exact-window independent recomputation, Investigation context, and bounded
self-observability.

## Milestone 9 scope

Status: COMPLETE

M9 adds the smallest stateless Alert Evaluation boundary over canonical M8 burn
evidence. A deployment-managed read-only policy references an SLO and has one inclusive
`BURN_RATE_ABOVE` condition: available unrounded canonical burn at or above its finite
non-negative threshold is `CONDITION_MET`; a lower available value is
`CONDITION_NOT_MET`. Valid zero remains evidence. Unavailable burn evidence—including
no traffic, Metrics unavailability, invalid telemetry, and zero allowed bad ratio—maps
to `UNAVAILABLE` with its bounded reason. A disabled policy is not evaluated and returns
`UNAVAILABLE/DISABLED`, never a healthy result.

Each result preserves exact service namespace/name/environment identity, inherited
configured window, absolute range, evaluation time, threshold, observed burn when
available, and Investigation context. M9 consumes canonical SLO/Burn evidence; it does
not query VictoriaMetrics or reimplement request counts, bad ratios, or burn formulas.

M9 adds no notification delivery, pages, email/webhooks, routing, escalation,
acknowledgement, silencing, maintenance windows, incidents, persistent firing/resolved
lifecycle, history, scheduler, policy CRUD/reload, generic expressions, arbitrary
PromQL/MetricsQL/TraceQL/LogQL, topology inhibition, multi-window paging, storage, or
Milestone 10 work. All mandatory local verification and independent review passed with
no remaining BLOCKER or HIGH finding. The authoritative GitLab pipeline passed the
preceding Service Map, SLO, and Burn Rate gates and the M9 Alert Evaluation semantic
smoke, so M9 is `COMPLETE`.

## Milestone 10 scope

Status: COMPLETE

M10 extends the existing alerts bounded context with durable current state. An explicit
POST command consumes the canonical M9 result exactly once and applies the closed
`INACTIVE`/`FIRING` transition table. Only inactive-to-firing `ALERT_STARTED` and
firing-to-inactive `ALERT_RESOLVED` changes are emitted. `UNAVAILABLE`, including
`DISABLED`, freezes state. The current-state GET is side-effect-free.

File-backed H2 with Flyway and a Compose named volume provides restart-safe state for
the supported single-node runtime. Provider-neutral optimistic compare-and-set,
immutable policy/SLO/condition/service/window binding, and monotonic evidence time
prevent duplicate, stale, and cross-policy transitions. The UI presents lifecycle
state separately from M9 condition evidence and preserves exact Investigation context.

M10 adds no scheduler, transition history, episode model, outbox, notification,
routing, retry, acknowledgement, silence, escalation, maintenance window, or incident.
The authoritative GitLab semantic chain passed M8 Burn Rate, M9 Alert Evaluation, and
M10 Alert Lifecycle after checking out the Alert Lifecycle Persistence Health fix at
commit `4a81d9f8`. No BLOCKER or HIGH finding remained at the M10 boundary. M11 now
implements the notification-delivery foundation below.

## Milestone 11 scope

Status: COMPLETE

M11 atomically persists eligible canonical M10 transitions with durable webhook work,
then processes it with a bounded single-node lease worker. Stable delivery IDs support
receiver deduplication. Retryable transport/429/5xx outcomes use durable bounded retry;
other 4xx responses are terminal. Delivery never mutates lifecycle state. Configuration
supplies one webhook and secret; there is no runtime CRUD, API/UI, evaluation scheduler,
broker, email adapter, incident workflow, or exactly-once claim.

Independent review completed with no remaining BLOCKER or HIGH findings. Authoritative
GitLab semantic revalidation on `main` at commit `f087da71` passed M9 Alert Evaluation,
M10 Alert Lifecycle, and M11 Notification Delivery. Repository tests cover atomic
lifecycle/outbox persistence; the M11 smoke exercised STARTED/RESOLVED delivery, stable
identity, bounded retry, restart recovery, no-transition suppression, terminal success,
and the checked token/telemetry boundaries.

## Milestone 12 scope

Status: COMPLETE

M12 adds deployment-managed automatic evaluation for enabled alert policies. A bounded
single-node scheduler triggers the existing M9 evaluation and M10 lifecycle path; M11
continues to own durable webhook delivery. Scheduling is disabled by default, supports
bounded workers and queue capacity (including direct hand-off capacity `0`), suppresses
same-policy overlap, and has no leader election, distributed lock, or missed-tick
replay. The authoritative GitLab pipeline passed backend quality gates, deployment
configuration, frontend verification, verified-JAR and runtime-image provenance, and
`local_stack_smoke`. The M9 → M10 → M11 → M12 chain verified automatic transitions,
M11 delivery, outage isolation/recovery, restart recovery, disabled-policy suppression,
bounded telemetry, and secret isolation.

## Milestone 13 scope

Status: COMPLETE

M13 adds deployment-managed, deterministic routing at the existing M10/M11 transition
boundary. A canonical lifecycle transition is routed once as `MATCHED(destination)`,
`SUPPRESSED`, or `UNROUTED`; only a matched destination creates durable delivery work.
The M11 worker dispatches the persisted destination binding and does not reroute during
retry or restart.

The authoritative GitLab pipeline passed backend verification, deployment
configuration, frontend verification, and `local_stack_smoke`, including the M9–M12
regression chain. The isolated M13 semantic smoke verified route A/B isolation,
explicit suppression and unrouted outcomes, the durable no-delivery boundary, persisted
destination binding across retry/restart, notification security isolation, and bounded
routing telemetry. No known BLOCKER or HIGH issue prevents closure.

## Milestone 14 scope

Status: READY FOR GITLAB REVALIDATION

M14 adds durable alert episodes and immutable canonical transition history. The bounded
read-only history API is committed with the winning M10 lifecycle update; M10 remains
authoritative for current `INACTIVE`/`FIRING` state. M14 adds no UI, retention automation,
acknowledgements, silences, maintenance windows, incidents, or routing changes.
Local closure validation passed the rebuilt runtime, exact M14 semantic smoke, and
ordered M9–M13 regression chain. GitLab revalidation remains required before milestone
completion.
