# Notification Delivery

Status: M11 COMPLETE; M17 implementation in progress

## Scope

Notification Delivery is an Alerts capability that consumes only canonical committed
M10 `ALERT_STARTED` and `ALERT_RESOLVED` transitions. It does not evaluate alerts,
query SLO or Metrics evidence, or schedule lifecycle evaluation.

## Reliability boundary

The lifecycle persistence adapter atomically commits a winning lifecycle CAS update,
the M14 episode/immutable transition-history mutation, an M17 immutable disposition
fact, and an immutable delivery record when M13 returns `MATCHED`. `SUPPRESSED` and
`UNROUTED` transitions commit lifecycle, history, and their exact disposition without
creating delivery work. The worker dispatches a matched delivery record only after
commit. A crash before the transaction commits persists none of these changes; a crash
after it commits leaves the work recoverable. HTTP delivery is outside the database
transaction.

Delivery is at-least-once from Geordi's perspective. A response can be lost after a
receiver processes a request, so a stable delivery ID is supplied for receiver-side
deduplication. Geordi never claims exactly-once network delivery.

## Processing

Records progress through `PENDING`, `LEASED`, `DELIVERED`, or terminal `FAILED`.
A bounded worker leases due work with a claim token and expiry, atomically consuming
the attempt before HTTP. Completion and retry updates require that token, preventing
stale workers from overwriting reclaimed work. Lease expiry makes interrupted work
recoverable after restart without bypassing the maximum attempt count. The supported
topology is single-node only.

Only 2xx succeeds. 429, 5xx, connection failures and timeouts retry with bounded
durable backoff; other 4xx responses are terminal. Delivery never changes the alert's
M10 `FIRING` or `INACTIVE` state.

M16 episode acknowledgement is outside notification delivery. Creating or replaying
an acknowledgement does not create outbox work, cancel pending delivery, prevent
delivery, reroute an existing delivery, re-drive failed work, modify retry, suppress
dispatch, or alter the persisted destination binding. M11/M13 delivery semantics remain
unchanged.

## M17 episode-detail evidence

M17 adds a read-only notification projection to episode detail only. It presents the
immutable disposition `MATCHED`, `SUPPRESSED`, or `UNROUTED`; `NOT_RECORDED` means no
durable disposition fact is present and is never stored or inferred from current
routing. Detail may include delivery status only for exactly correlated durable work.
The transition-list API remains unchanged.

`PENDING` exposes created and next-attempt times; `LEASED` exposes only created time;
`DELIVERED` and `FAILED` expose created and completed times. `LEASED` means completion
is not durably recorded and may await recovery. `DELIVERED` means Geordi recorded an
accepted HTTP 2xx response, not human receipt or exactly-once network delivery.

The projection exposes neither destination nor delivery identity, payload, webhook
configuration, credentials, claims, leases, or arbitrary failure text. Inconsistent or
malformed durable notification evidence fails the complete episode detail through the
sanitized Alerts-unavailable boundary rather than returning partial data.

## Webhook safety

One deployment-managed webhook destination is supported. Production requires HTTPS;
the local deterministic smoke receiver is the sole explicit HTTP exception. Redirects
and URI user-info are rejected. Tokens live only in deployment secrets and never in
the outbox, APIs, payload logs, metrics, or trace attributes.

Pending work stores destination identity and a non-secret configuration fingerprint.
Changed configuration cannot silently reroute it: claimed incompatible work is marked
terminally failed. Disabled dispatch preserves pending work; transitions created while
disabled are not backfilled.

## Observability and health

Delivery reports low-cardinality attempts, results, retries, unexpected failures, and
duration using only closed outcome/transition labels. M17 additionally records bounded
notification-commit and projection outcomes, plus integrity-failure reason, without
duplicating M11 worker metrics. It never uses policy, service, destination, URL,
delivery ID, or error text as labels. A remote recipient outage is a delivery outcome,
not platform unhealthiness. Unavailability of Geordi's lifecycle, outbox, or M17
disposition store makes Alerts/readiness DOWN.

## Operational limitations

M11 supports one deployment-managed webhook in a local single-node topology. It has no
multi-node ownership, exactly-once receiver guarantee, dead-letter or operator re-drive
workflow, retention management, global delivery dashboard/search, delivery command,
additional channel, or alert evaluation scheduler. M17 is a bounded episode-detail
projection, not delivery management. Receivers must deduplicate by the stable delivery ID.

## Closure validation

Independent review completed with no remaining BLOCKER or HIGH findings. Authoritative
GitLab semantic revalidation on `main` at commit `f087da71` passed the M9 Alert
Evaluation, M10 Alert Lifecycle, and M11 Notification Delivery smokes. Repository tests
cover atomic lifecycle/outbox persistence. The M11 smoke observed STARTED/RESOLVED
delivery, stable identity, retry and pending-work recovery after restart, no-transition
suppression, terminal success, bounded result labels, and no configured token in the
checked public API or backend/fixture logs.

## Milestone 12 scheduling handoff

M12 schedules the canonical lifecycle use case only. A winning M10 transition still
creates M11 outbox work atomically and this worker remains unchanged. Local M12 semantic
evidence observed exactly one STARTED and one RESOLVED webhook across automatic
evaluation, provider outage/recovery, and backend restart. This does not change the
single-node, at-least-once delivery contract.
