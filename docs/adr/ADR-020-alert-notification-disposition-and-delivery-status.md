# ADR-020: Alert Notification Disposition and Delivery Status

Status: ACCEPTED — locally implemented and validated; authoritative GitLab revalidation pending

## Context

M10 owns current `INACTIVE`/`FIRING` lifecycle state and derives canonical
`ALERT_STARTED` and `ALERT_RESOLVED` transitions. M14 owns immutable episode and
transition-history facts. M13 owns the routing decision for a canonical transition,
and M11 owns the mutable durable delivery work created for a matched route.

Those existing facts do not let an operator reading an episode determine whether
Geordi matched, suppressed, or found no route for a recorded transition. Nor can the
episode detail safely expose the bounded current status of matching delivery work
without defining a correlation and privacy boundary.

## Decision

Keep the capability in the Alerts bounded context. Add an immutable companion fact
for each M17-committed canonical transition with one persisted disposition:
`MATCHED`, `SUPPRESSED`, or `UNROUTED`. M14 remains authoritative for transition
identity and payload; M11 remains authoritative for mutable delivery state; M13
remains authoritative for routing semantics.

`NOT_RECORDED` is a read-model value only. It means no durable disposition fact exists
for the transition. It is not stored, does not assert that a transition predates M17,
and is never inferred from current routing configuration.

### Atomic write boundary

The application constructs one closed transition commit intent. It contains the M14
history mutation and exactly one notification case: matched with one delivery,
suppressed without delivery, or unrouted without delivery. A no-transition lifecycle
write has no such intent.

The successful lifecycle compare-and-set, M14 episode/history mutation, M17
disposition row, and matched-only M11 outbox row commit or roll back in one transaction.
The worker continues to run only after commit. A routing failure or losing CAS persists
none of these candidate facts; retries recompute the canonical transition under the
existing lifecycle rules.

### Persistence and compatibility

V7 adds `alert_notification_disposition` with a transition-ID primary key, foreign key
to M14 history, non-null disposition, and a closed-value check. It is additive and has
no backfill. After V7, one M17-capable writer is the supported writer against the
upgraded database; mixed pre-M17 and M17 writers are not supported in the single-node
topology.

For a transition with no disposition, historical delivery evidence is exposed only
when its delivery ID exactly equals the canonical transition ID and its parsed canonical
transition equals the M14 transition value. This compares canonical values rather than
timestamp columns because historical outbox and history storage have different timestamp
precision. A same-ID payload mismatch is an integrity failure, not hidden evidence.

### Read API, integrity, and disclosure

Only episode detail is enriched. A consistent detail projects the disposition and,
where truthful delivery evidence exists, a bounded delivery status. `MATCHED` requires
exactly correlated delivery; `SUPPRESSED` and `UNROUTED` require its absence. Violations,
malformed durable values, and invalid legacy correlation fail the entire detail as a
sanitized `503`, not a partial response.

The public delivery states are `PENDING`, `LEASED`, `DELIVERED`, and `FAILED`.
`PENDING` exposes created and next-attempt times; `LEASED` exposes only created time;
terminal states expose created and completed times. `LEASED` means completion is not
durably recorded and the lease may await recovery. `DELIVERED` means Geordi recorded an
accepted HTTP 2xx response, not human receipt or exactly-once network delivery.

The API, UI, logs, traces, metrics, and sanitized errors must not disclose destination
or delivery identity, payload, webhook data, credentials, claim/lease data, or arbitrary
error text. The change remains read-only and adds no retry, routing mutation, global
delivery search, or delivery-management command.

## Consequences

Episode detail can show durable notification evidence without making routing or delivery
state part of M14 history. The new table participates in Alerts persistence health, and
new telemetry is limited to low-cardinality commit, projection, and integrity outcomes.
The detail API intentionally differs from the unchanged transition-list representation.
