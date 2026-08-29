# Notification Delivery

## Scope

Notification Delivery is an Alerts capability that consumes only canonical committed
M10 `ALERT_STARTED` and `ALERT_RESOLVED` transitions. It does not evaluate alerts,
query SLO or Metrics evidence, or schedule lifecycle evaluation.

## Reliability boundary

The lifecycle persistence adapter atomically commits a winning lifecycle CAS update and
an immutable delivery record. The worker dispatches that record only after commit. A
crash before the transaction commits persists neither; a crash after it commits leaves
the work recoverable. HTTP delivery is outside the database transaction.

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
duration using only closed outcome/transition labels. It never uses policy, service,
destination, URL, delivery ID, or error text as labels. A remote recipient outage is a
delivery outcome, not platform unhealthiness. Unavailability of Geordi's lifecycle and
outbox store makes Alerts/readiness DOWN.
