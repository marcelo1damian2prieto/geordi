# Milestone 010 — Alert Lifecycle Foundation

Status: COMPLETE

## Objective

Add the smallest durable, explainable lifecycle layer over the canonical M9 Alert
Evaluation result. M10 answers whether an operational alert state changed; it does
not change how a policy is evaluated, deliver a notification, or manage an incident.

M10 completion requires the authoritative GitLab semantic pipeline to be green in
addition to local implementation and verification. That requirement is satisfied by
the closure evidence recorded below.

## Reconciled decision

The existing `alerts` logical bounded context is extended; no new module is created.
M9 remains the only producer of current policy evidence. M10 invokes that canonical
boundary exactly once for a lifecycle evaluation and never queries a provider,
reimplements SLO or burn-rate mathematics, or derives a second evidence range.

The lifecycle use case is an explicit state-changing operation:

```text
POST /api/alert-policies/{policyId}/lifecycle-evaluations
  -> canonical M9 evaluation
  -> atomically read current state / apply transition function / persist state
  -> current state + the transition produced by this request, if any

GET /api/alert-states
  -> persisted current states only; no provider evaluation and no state mutation
```

The POST response keeps the nested M9 evaluation distinct from lifecycle state and
transition. The read-only GET is for the small operational view; it is not alert
history, a transition feed, a notification queue, or a scheduler API.

## Ubiquitous language and scope boundary

| Term | M10 meaning | Not meaning |
| --- | --- | --- |
| Alert evaluation | One current, stateless M9 conclusion: `CONDITION_MET`, `CONDITION_NOT_MET`, or `UNAVAILABLE`. | A firing alert, a delivery, or an incident. |
| Alert state | Durable temporal operational state: `INACTIVE` or `FIRING`. | An evaluation status. |
| Alert transition | A meaningful state change: `ALERT_STARTED` or `ALERT_RESOLVED`. | A notification sent or an incident update. |
| Notification | A future consumer of a canonical transition. | M10 scope. |
| Incident | A future higher-level operational workflow. | M10 scope. |

No email, webhook, queue, routing, retry, acknowledgement, silencing, escalation,
incident, generic rule engine, episode identifier, or background evaluator belongs in
M10.

## State and transition contract

There are exactly two states: `INACTIVE` and `FIRING`. A missing state record behaves
as `INACTIVE`. A state is independently keyed by stable alert policy id. Its first
canonical evaluation establishes immutable policy id, SLO id, condition type and exact
threshold binding; once canonical evidence exists it also establishes exact service
identity and window binding. The state record persists and compares every established
binding before every later enabled update, so one policy's evidence can never drive
another policy's state.

The evidence range is deliberately not part of immutable binding: it is a dynamic
current evaluation window and must change over time. Each accepted evaluation still
validates and preserves its exact half-open range and the M9 coherence invariant
(`evaluatedAt == range.to()` and range length matches its window). A same-policy-id
binding mismatch fails closed, writes no state, and emits no transition; its semantic
meaning requires a new policy id rather than mutating a running lifecycle identity.
The M9 contract exposes SLO id, service identity, window, and evidence—not an SLO
target/definition fingerprint. Therefore a deployment must retain those semantic
identity fields for a policy/SLO pair; if an SLO definition change alters service
identity or window, it requires new identifiers. A target-only change is not observable
at this boundary and cannot be distinguished by M10; deployments needing a distinct
lifecycle semantic identity must use a new SLO/policy id.

| Previous state | Canonical M9 result | Current state | Transition | Required behavior |
| --- | --- | --- | --- | --- |
| none / `INACTIVE` | `CONDITION_MET` | `FIRING` | `ALERT_STARTED` | Establish or retain a firing state and set `startedAt` to canonical evidence `evaluatedAt`. |
| `FIRING` | `CONDITION_MET` | `FIRING` | none | Preserve the original `startedAt`; repeated evidence is not a repeated start. |
| none / `INACTIVE` | `CONDITION_NOT_MET` | `INACTIVE` | none | Establish or retain inactive state; do not fabricate resolution. |
| `FIRING` | `CONDITION_NOT_MET` | `INACTIVE` | `ALERT_RESOLVED` | Set `resolvedAt` to canonical evidence `evaluatedAt`; valid recovery evidence is required. |
| none / `INACTIVE` | `UNAVAILABLE` | `INACTIVE` | none | Retain/establish non-firing state and record unavailable evaluation metadata only. |
| `FIRING` | `UNAVAILABLE` | `FIRING` | none | Preserve firing and `startedAt`; unknown evidence is not recovery. |
| `INACTIVE` or `FIRING` | `UNAVAILABLE/DISABLED` | unchanged | none | Retain the state and mark the latest evaluation disabled; disabling is not telemetry recovery. |

Thus first `CONDITION_MET` starts an alert, first `CONDITION_NOT_MET` never resolves
one, and first `UNAVAILABLE` never activates one. Repeated `CONDITION_MET` while
firing and repeated `CONDITION_NOT_MET` while inactive are idempotent state
observations with no transition.

`UNAVAILABLE` includes all M9 bounded unavailable reasons, including no traffic,
invalid or missing telemetry, Metrics unavailability, zero allowed bad ratio, and
`DISABLED`. It is neither `CONDITION_MET` nor `CONDITION_NOT_MET`. A disabled policy
continues to use M9's `UNAVAILABLE/DISABLED` result without evaluating its SLO; M10
freezes lifecycle state rather than resolving it.

## Current state, latest transition, and time

M10 persists current state and at most the latest canonical transition metadata needed
to explain it. It deliberately provides no transition list, historical episodes,
timeline, audit stream, or outbox. `startedAt` is meaningful only while firing;
`resolvedAt` is meaningful only for the current inactive record after the latest
resolution. A subsequent start clears prior resolved metadata. This limited current
record is not alert history.

No episode id is introduced: with one current record and no history/incident workflow,
it has no concrete use. A later milestone may make a separate, explicit episode and
retention decision.

For enabled results, transition `occurredAt`, `startedAt`, and `resolvedAt` equal the
canonical M9 evidence `evaluatedAt`, whose evidence range is exact and half-open
`[from,to)`. M10 does not call a second clock for those facts. Disabled M9 results have
no evidence by design; if persistence needs an operation timestamp for such metadata,
M10 obtains one `processedAt` from an injected `Clock`, clearly distinguished from
telemetry evidence time. Tests use a fixed clock.

For enabled evidence, the record also persists `lastAppliedEvidenceEvaluatedAt`. An
evaluation strictly older than that timestamp is returned as `STALE_IGNORED`: no state
change, no metadata reordering, and no transition. An evaluation with the same timestamp
is `DUPLICATE_IGNORED`: first writer wins, with no state change or transition. Only a
strictly newer timestamp is eligible for the transition table. Disabled evaluations have
no evidence timestamp; their `processedAt` is metadata only and cannot reorder,
supersede, or transition evidence-driven state.

## Persistence, restart, and concurrency

Durable state is required because M10 claims restart-safe deduplication. The selected
implementation is embedded file-backed H2 with Flyway migrations, mounted in Compose
as a named volume. It adds no database service and is appropriate to this bounded,
single-node modular-monolith milestone.

| Alternative | Decision |
| --- | --- |
| In-memory map | Rejected: restart loses firing state and can duplicate starts/resolutions. |
| File-backed embedded H2 + Flyway | Selected: durable local state, schema versioning, no new Compose service, bounded operational complexity. |
| External relational database | Deferred: production-plausible but adds a service, credentials, operations, CI cost, and distributed-concurrency scope not justified by M10. |

The domain/application boundary owns a provider-neutral compare-and-set lifecycle
repository port. The H2/Flyway adapter is infrastructure only. Each update atomically
reads the policy's current version, applies the pure transition function, and writes
only if its expected version matches. On a compare-and-set conflict, it rereads and
reapplies the same canonical evaluation until success or a bounded failure. Therefore
concurrent same-policy requests cannot both emit logical `ALERT_STARTED` or
`ALERT_RESOLVED`; different policy ids remain independent. This is a single-node
strategy, not distributed consensus.

After process restart, persisted state and latest transition metadata reload; a firing
policy remains firing and repeated met evidence produces no start. The M10 durable
claim is limited to the configured named volume. Deleting that volume is an explicit
state reset, not a recovery guarantee.

Before any write, lifecycle processing validates that the returned M9 evaluation is
semantically bound to the requested policy and persisted binding: policy id, SLO id,
condition type/threshold, and—once evidence exists—exact service identity and window
must agree. The dynamic range must remain internally coherent and is preserved rather
than compared as stable identity. A mismatch fails closed: it leaves existing lifecycle
state unchanged, creates no transition, and returns a controlled failure. It must never
use mismatched evidence to activate or resolve another policy.

## Scheduler and future notification boundary

M10 has no scheduler. Lifecycle correctness is proven by explicit POST evaluation;
adding periodic cadence, overlap rules, provider load, startup/shutdown behavior, and
background failure semantics would exceed this milestone. Current-state reads never
evaluate a policy. Operators or a future bounded scheduler may explicitly request a
lifecycle evaluation later.

The canonical `AlertTransition` is designed as the future Notification Delivery input:
policy identity, type, previous/current state, occurrence time, canonical service
identity, exact evidence range/window, and an evaluation snapshot/reference. A future
delivery adapter must not learn SLO mathematics or provider details. M10 does not
persist an outbox or dispatch any transition; delivery reliability and routing remain a
future, separately designed concern.

## API and UI scope

OpenAPI is updated before frontend work. The POST result exposes the exact M9
evaluation, persisted current lifecycle state, and nullable transition generated by the
request. `GET /api/alert-states` returns bounded current records only. API/UI wording
must use `Condition met`/`Condition not met` for evaluation and `Firing`/`Inactive` for
state, never claim that a notification was sent or an incident was created.

The smallest UI shows current state, latest evaluation status/reason, canonical service
identity, exact evidence range, last evaluated/processed time with its source clear,
started/resolved time when meaningful, and existing exact-context Investigation
navigation. It does not become alert management or alert history.

## Verification and documentation plan

1. Unit-test the full transition table, first/repeated behavior, unavailable and
   disabled freezing, timestamps, semantic-binding failure, and no episode semantics.
2. Test repository compare-and-set races for concurrent start and resolve requests;
   assert exactly one logical transition in each case.
3. Test restart while firing against file-backed H2 and confirm repeated met evidence
   has no second start.
4. Add a deterministic lifecycle semantic smoke with isolated policies/evidence. Its
   independent oracle validates state and transition results from M9 evidence, repeated
   start/resolve behavior, unavailable false recovery/activation, disabled
   unavailability, restart durability, and exact identity/range preservation. Focused
   automated tests cover disabled-while-firing, stale/concurrent processing, and binding
   mismatch cases that do not require a test-only runtime mutation API.
5. Start CI integration from a fresh named lifecycle volume. A standalone full smoke
   likewise requires the operator to remove the stopped prior Compose stack and its
   volumes before starting the stack; the running smoke never performs that destructive
   operation. There is no reset API or test-only reset mechanism. GitLab performs a
   project-scoped `down --volumes --remove-orphans` before startup and repeats it in the
   unconditional `after_script`; a smoke must never delete a live volume.
6. Add the smoke after M9 Alert Evaluation in the authoritative GitLab chain, without
   removing preceding regression gates.
7. Verify Compose volume configuration, Flyway migration, backend/frontend quality
   gates, existing smokes, and no notification or incident provider/configuration.
8. Update architecture, API, product, startup, deployment, and technical-debt
   documentation in step with implementation; obtain independent review and fix every
   BLOCKER/HIGH finding.

## Closure

- Implementation is complete, including the Alert Lifecycle Persistence Health fix.
- The authoritative GitLab `local_stack_smoke` job checked out commit `4a81d9f8` and
  passed the required semantic validation chain.
- The M9 Alert Evaluation and M10 Alert Lifecycle semantic smokes passed; the preceding
  M8 Burn Rate smoke also remained green.
- The M10 smoke passed durable lifecycle transitions, exact canonical evidence,
  restart survival, firing-state unavailability freeze, disabled unavailability, its
  independent provider oracle, Investigation context, and bounded telemetry.
- Backend verification is green with 214 tests plus ArchUnit, PMD, SpotBugs, and Find
  Security Bugs.
- No BLOCKER or HIGH finding remains.
- Milestone 11 has not started. Scheduler, lifecycle history, notifications, incidents,
  multi-node guarantees, and exactly-once delivery remain outside M10.
