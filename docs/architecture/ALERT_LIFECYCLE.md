# Alert Lifecycle Architecture

Status: MILESTONE 10 COMPLETE

## Scope

Alert Lifecycle adds temporal operational meaning to M9's stateless Alert Evaluation.
It answers whether the current lifecycle state changed for one policy. It does not
alter the M9 comparator or evidence, query telemetry providers, calculate burn rate,
send notifications, or create incidents.

```text
canonical M9 Alert Evaluation
        |
        v
Alert Lifecycle transition function
        |
        v
durable current alert state + optional canonical transition
        |
        `-- M11 durable notification-delivery handoff (implemented outside transition logic)
```

`CONDITION_MET` is an evaluation result, not itself a firing transition. `FIRING` is a
state, not a notification. `ALERT_RESOLVED` is a transition, not an incident closure.

## Ownership and dependency direction

The existing `alerts` bounded context owns lifecycle state, the pure transition
function, canonical transition values, and an application repository port. It consumes
the existing alerts-owned M9 evaluation use case exactly once. Alerts domain and
application remain independent of Spring, H2, Flyway, JDBC, telemetry SDKs, SLO/Metrics
types, provider query languages, notifications, and incident systems.

The H2/Flyway persistence implementation and HTTP endpoints are adapters. The M9 SLO
composition adapter remains the only alerts code allowed to call the SLO boundary; no
lifecycle code may bypass M9 to reach SLO, burn, Metrics, or a provider. The M11
notification adapter consumes canonical `AlertTransition` values from this boundary;
it does not depend on VictoriaMetrics, PromQL/MetricsQL, SLOs, or burn-rate formulas.

## Canonical state machine

States are deliberately limited to `INACTIVE` and `FIRING`. The absence of a persisted
record is interpreted as `INACTIVE` for transition purposes.

| Previous state | M9 evaluation | State after processing | Transition |
| --- | --- | --- | --- |
| none / `INACTIVE` | `CONDITION_MET` | `FIRING` | `ALERT_STARTED` |
| `FIRING` | `CONDITION_MET` | `FIRING` | none |
| none / `INACTIVE` | `CONDITION_NOT_MET` | `INACTIVE` | none |
| `FIRING` | `CONDITION_NOT_MET` | `INACTIVE` | `ALERT_RESOLVED` |
| none / `INACTIVE` | `UNAVAILABLE` | `INACTIVE` | none |
| `FIRING` | `UNAVAILABLE` | `FIRING` | none |
| either state | `UNAVAILABLE/DISABLED` | unchanged | none |

`UNAVAILABLE` is never converted to a healthy or bad condition. It includes disabled
policy, no traffic, missing/invalid telemetry, Metrics unavailability, and zero allowed
bad ratio. In particular, a disabled policy freezes a firing state rather than resolving
it, because a configuration action is not evidence of recovery.

The first successful met condition starts; the first successful not-met condition does
not resolve; the first unavailable condition does neither. Repeated met evidence while
firing and repeated not-met evidence while inactive produce no duplicate transition.

## State record, evidence, and time

One durable current record exists per policy id. Its first canonical evaluation
establishes and persists immutable policy id, SLO id, condition type, and threshold
binding; once evidence exists it also establishes exact service identity and window
binding. Later enabled evaluations compare every established value before they can
mutate the record. Same-id semantic binding mismatch fails closed with no state write
and no transition; it requires a new policy id rather than changing the semantic
identity of an existing lifecycle record.

The range is intentionally dynamic and is not a binding key. Every accepted evaluation
nevertheless validates and preserves its exact half-open range, including its coherence
with the canonical window and `evaluatedAt`. M9 exposes no SLO target/definition
fingerprint. Deployments must therefore retain the same observable SLO semantic
identity (SLO id, service identity, and window) for a policy; a definition change that
alters service identity or window requires a new SLO/policy id. A target-only change is
not observable by M10, so a deployment needing a distinct lifecycle semantic identity
must issue a new identifier.

The record also holds current state, state version, latest M9 evaluation metadata, and
at most the latest canonical transition metadata needed to explain the current record.
There is no alert history collection, transition feed, episode identity,
acknowledgement, silencing, incident state, or notification outbox in M10.

Enabled M9 evidence carries exact policy/SLO/service context, window, half-open
`[from,to)` range, and canonical `evaluatedAt`. Lifecycle start/resolve `occurredAt`
and `startedAt`/`resolvedAt` use this exact timestamp. The lifecycle layer creates no
second evidence time or range. Disabled M9 evaluations intentionally have no evidence;
only their processing metadata may use a single injected `Clock` timestamp, named
`processedAt` and never represented as telemetry evidence time.

The record persists `lastAppliedEvidenceEvaluatedAt` for enabled evidence. An older
evaluation is explicitly `STALE_IGNORED`: it changes neither state nor metadata and
produces no transition. An equal timestamp is `DUPLICATE_IGNORED`: first writer wins
and the result likewise has no state change or transition. Only strictly newer evidence
can enter the state machine. A disabled evaluation has no evidence timestamp;
`processedAt` remains descriptive metadata and never reorders or supersedes
evidence-driven state or transitions.

Before mutation, the application validates the M9 response against the requested
policy and persisted semantic binding: policy id, SLO id, condition type/threshold,
and, once evidence exists, service identity and window must agree. Its dynamic range
must remain internally coherent but is not treated as immutable identity. Any mismatch
fails closed with no state write and no transition.

## Durable state and atomicity

File-backed embedded H2 plus Flyway migrations persist the current records. Compose
mounts its data directory as a named volume. This provides restart-safe deduplication
without adding an external database service. It is intentionally a single-node MVP
design; a multi-node deployment needs a later explicit persistence/concurrency ADR.

The provider-neutral lifecycle repository port offers compare-and-set update semantics.
For one policy the application atomically reads its version, applies the transition
function, and conditionally writes the new record. A conflict retries by rereading and
reapplying the same canonical evaluation within bounded limits. This prevents concurrent
same-policy evaluations from generating duplicate logical starts or resolutions.
Restart reloads the record, so a firing policy stays firing and a repeated met condition
does not create another start. CI obtains isolated state by starting with a fresh named
volume and removes it only during unconditional final Compose cleanup. A standalone
smoke normalizes its isolated policy through canonical evidence; no runtime reset
endpoint or live-volume deletion is permitted.

## API, UI, and scheduling

`POST /api/alert-policies/{policyId}/lifecycle-evaluations` explicitly evaluates M9 and
applies lifecycle state. Its response contains separate evaluation, current state, and
nullable transition fields. `GET /api/alert-states` is read-only over durable current
records and does not call M9 or a provider.

The UI presents state (`Firing`/`Inactive`) separately from the latest M9 condition
result, unavailable reason, and evidence. It preserves exact Investigation navigation
only from canonical evidence identity/range. It must not say a transition was delivered,
or that an incident exists.

M12 adds a single-node inbound scheduling adapter that invokes this same canonical
lifecycle use case; the explicit POST remains available. The scheduler does not own
evaluation, state transitions, outbox delivery, lifecycle persistence, or job
persistence. It is deployment-managed, disabled by default, has bounded workers and
queue capacity, suppresses per-policy overlap through the shared lifecycle single-flight
coordinator, and has no leader election, distributed lock, or missed-tick replay.

## Observability and validation

While Alerts is enabled, module health runs a bounded, read-only lifecycle persistence
probe. Persistence connectivity, schema, or read-access unavailability makes Alerts
health and platform readiness `DOWN`. Disabling Alerts skips the Alerts persistence
health requirement. The probe is intentionally read-only: it verifies the lifecycle
store can be reached and its schema can be read, but does not claim that every write-path
failure mode is available.

Lifecycle self-observability uses bounded result/transition/outcome labels only. It
never labels by policy, SLO, service, namespace, environment, timestamp, evidence
value/range, exception, or provider syntax. Telemetry distinguishes an unavailable
evaluation from a transition failure without turning either into a lifecycle transition.

The lifecycle semantic smoke independently drives and checks the state table, including
first/repeated met and not-met, exact evidence identity, provider unavailability while
firing, an explicitly disabled inactive policy, and restart while firing. Focused domain,
application, web, and persistence tests prove disabled-while-firing freeze, immutable
policy/SLO/service/window binding, stale/duplicate ordering, controlled persistence
failure, and one logical transition under concurrent writers.

CI removes the project-scoped stopped Compose stack and volumes before startup, then
starts the integration stack with a fresh named lifecycle volume. A standalone full
smoke requires the operator to do the same; smoke code never deletes a live volume.
There is no reset API or test-only reset mechanism. GitLab `after_script` also tears down
the stack with Compose `down --volumes`. The smoke runs after the M9 smoke in
authoritative GitLab CI, and existing smokes remain mandatory. Notification delivery,
incident management, and scheduler coverage were intentionally absent from M10; M11
adds only the notification-delivery foundation.

The authoritative GitLab semantic chain passed the M9 Alert Evaluation and M10 Alert
Lifecycle smokes after checking out commit `4a81d9f8`, including the persistence-health
fix. No BLOCKER or HIGH finding remained at the M10 boundary.
