# ADR-019: Durable Alert Episode and Transition History Boundary

Status: ACCEPTED — implemented in M14; ready for GitLab revalidation

## Context

M10 owns the authoritative current lifecycle state (`INACTIVE`/`FIRING`) and
derives canonical `ALERT_STARTED` and `ALERT_RESOLVED` transitions. M11 persists
delivery work for a routed transition in the winning lifecycle transaction; M13
routes before that commit. Neither has durable episode or transition history.

M14 needs an operator-readable, restart-safe account of committed canonical
transitions without changing evaluation, routing, or delivery semantics.

## Decision

Keep this capability in the existing Alerts bounded context. Add a small episode
projection and immutable transition ledger behind an Alerts application port,
implemented by the existing H2/Flyway adapter and datasource. This is history,
not event sourcing: M10 current lifecycle remains authoritative for present state;
the ledger is authoritative only for the successfully recorded history from M14
onward.

For a candidate canonical transition the application flow is:

1. M9 evaluates once and M10 derives the transition from its CAS snapshot.
2. M14 creates a pure, unpersisted episode/ledger mutation intent. A start
   requests a new episode; a resolution requests closure of the sole open episode.
3. M13 routes that canonical transition exactly once. A routing failure aborts
   before any database mutation.
4. One repository transaction conditionally writes the lifecycle version, applies
   the M14 intent, inserts the immutable ledger row, and, only for `MATCHED`, adds
   the existing M11 outbox work. A lost CAS rolls back all of it and causes the
   existing reread/reapply retry. `SUPPRESSED` and `UNROUTED` still persist lifecycle,
   episode, and ledger, but no outbox row.

The worker remains strictly after this commit. It neither reads history to make a
decision nor reruns routing.

### Episode and ledger model

Use two tables rather than deriving episodes solely from a ledger. An episode makes
open/closed and duration queries bounded and explicit; a ledger preserves immutable
transition facts. An embedded-metadata-only episode table loses a general immutable
timeline. A ledger-only model makes open-episode validation and common reads needlessly
expensive.

`alert_episode` contains a generated opaque `episode_id`, `policy_id`, nullable `opened_at`,
`closed_at`, and `origin`. `opened_at` is the canonical start time for normal M14
episodes; `closed_at` is the canonical resolution time. `origin` is `M14` or the
explicit upgrade-only `PRE_M14_UNKNOWN_START`. A normal `M14` row is validated to
have a non-null `opened_at`; only the legacy origin may have it null. A generated nullable `open_policy_id`
whose value is `policy_id` only while open has a unique constraint, enforcing at most
one open episode per policy while allowing closed history.

`alert_transition_history` contains an opaque deterministic `transition_id`,
`episode_id`, policy id, type, occurrence time, previous/current state, exact
canonical service identity/window/range, and the safe condition/evaluation status
needed to explain the transition. It has unique `(policy_id, transition_type,
occurred_at)`, the existing canonical delivery-identity inputs. It does not contain a
routing result, destination, webhook URL, secret, raw provider payload, or delivery
status. The one normal start and one normal resolve record both reference their episode.

Normal M14 episode identity is deterministic `hex(SHA-256(policyId + "\\n" + startedAt.toString()))`; legacy `PRE_M14_UNKNOWN_START` identity is deterministic `hex(SHA-256(policyId + "\\nPRE_M14_UNKNOWN_START\\n" + resolvedAt.toString()))`. Both use UTF-8, newline delimiters, canonical UTC `Instant.toString()` and lowercase hex. The legacy rule uses only the policy ID, explicit legacy discriminator, and genuine canonical `ALERT_RESOLVED` occurrence: it never fabricates a start timestamp or STARTED transition. They remain stable across CAS retry and restart, are independent of routing, destination, delivery, URLs and secrets, and the discriminator gives normal and legacy episodes separate identity namespaces.

The transition ID uses `hex(SHA-256(policyId + "\\n" + transitionType.name() + "\\n" + occurredAt.toString()))`, exactly M11's canonical delivery-identity inputs and encoding. It deliberately matches (but does not replace) M11's logical delivery identity inputs; no extra delivery meaning is introduced.

The CAS makes same-policy transition creation single-winner. Inside the successful
transaction, a start with an existing open episode, a normal resolve without one, an
unexpected duplicate ledger key, or an episode/ledger linkage mismatch is an invariant
violation: roll back, emit bounded observability, and return a controlled persistence
failure. M14 never silently repairs rows. Stale, duplicate, unavailable, disabled, and
no-transition M10 outcomes have no M14 mutation.

### Upgrade

No historical timestamps or start records are synthesized. A pre-M14 persisted
`FIRING` record remains valid current state but has no visible episode while firing.
When it first resolves, the winning transaction creates and immediately closes a
`PRE_M14_UNKNOWN_START` episode with `opened_at = NULL`, writes only the real
`ALERT_RESOLVED` ledger record, and exposes duration as unavailable. This preserves
the resolution and its linkage without claiming a fabricated start. New M14 starts
always create normal complete episodes. A later normal start after a legacy resolution
is fully tracked. This one exception is explicit in the API and tests.

## Read API and retention

Expose read-only endpoints:

- `GET /api/alert-episodes?policyId=&state=OPEN|CLOSED&from=&to=&limit=` returns
  newest-first episodes, default 50, maximum 100, with a required bounded 31-day
  absolute half-open `[from,to)` range unless `policyId` is supplied; policy-scoped queries may omit the
  range but remain limited.
- `GET /api/alert-episodes/{episodeId}` returns one episode and its at-most-two normal
  transition records (or one legacy resolution).
- `GET /api/alert-transitions?policyId=&episodeId=&from=&to=&limit=` returns
  newest-first `(occurredAt, transitionId)` ordering, default 100, maximum 200, and
  a required 31-day half-open range unless narrowed by policy or episode.

`from` and `to` are RFC 3339 UTC instants, must be supplied together, and must satisfy
`from < to` and `to - from <= 31 days`; invalid values, partial/excessive ranges,
invalid enum/ID/limit values, or unsupported filter combinations return the existing
RFC 9457 `400 Problem` response. Episode range membership is by `opened_at` (legacy
unknown-start rows require policy scope); transition membership is by `occurred_at`.
Detail lookup is not range-filtered.

All reads query only the M14 store, never M9/providers and never lifecycle mutation.
M14 has no automatic deletion: bounded reads and retention documentation are the
smallest safe foundation. Age/count cleanup needs separate operational policy,
transactional deletion rules, and an ADR; defer it.

## UI, observability, and safety

M14 adds no UI. The existing lifecycle page continues to be the current-state view;
a history screen risks expanding into incident workflow before the bounded API and
operator use are validated.

Add low-cardinality counters for episode open/resolve, successful/failed history
persistence, history query result/failure, and invariant violation. Labels may use
only closed outcome/type values. Never label with policy, service, route, destination,
episode/transition ID, URL, secret, or exception text. The Alerts read-only persistence
health probe must include the two new schemas.

## Consequences and non-goals

M14 requires additive Flyway migrations for the history schema and its pre-release
integrity/precision hardening, plus replacement of the optional-delivery
commit with an unconditional transactional transition-commit port: even
`SUPPRESSED`/`UNROUTED` history commits use the one transaction. It adds no datastore, external service, scheduling behavior, or
worker behavior. It does not introduce acknowledgements, comments, owners, incidents,
silences, maintenance windows, inhibition, escalation/on-call, fan-out, configuration
CRUD/reload, a generic expression engine, distributed coordination/HA, retention
cleanup, or M15 work.
