# Milestone 11 — Notification Delivery Foundation

Status: READY FOR GITLAB REVALIDATION

## Objective and product value

Deliver the smallest reliable path from a canonical, committed M10
`ALERT_STARTED` or `ALERT_RESOLVED` transition to a deployment-configured webhook.
The operator gains durable, restart-safe notification work without introducing alert
evaluation scheduling, notification administration, or incident management.

## Current-state evidence

- M10 evaluates only by explicit command: `AlertLifecycleService` reads canonical M9
  evidence once, applies the transition table, and persists only lifecycle state with
  CAS (`backend/src/main/java/io/geordi/alerts/application/AlertLifecycleService.java`).
- `AlertTransition` is the canonical transition evidence and carries its canonical
  evaluation (`backend/src/main/java/io/geordi/alerts/domain/AlertTransition.java`).
- H2/Flyway is the existing durable single-node store; lifecycle persistence is a
  separate adapter behind `AlertLifecycleRepository`.
- M10 explicitly has no scheduler or outbox (`docs/architecture/ALERT_LIFECYCLE.md`,
  `docs/plans/MILESTONE-010.md`).

## Architecture decision

Notification delivery remains inside the **Alerts** bounded context. It is a new
alerts domain/application slice—not a dependency of SLO, Metrics, Traces, Logs, or
Alert Evaluation. The lifecycle application service owns the handoff because it is
the only component that knows a transition won the CAS. A transactional persistence
adapter will atomically persist the winning lifecycle state and a notification outbox
row. This avoids a cross-module dependency and the lost-delivery gap between separate
state and webhook actions.

The scope has one adapter: an HTTP webhook. Application/domain code uses a
provider-neutral delivery port and payload value objects; URL, HTTP headers, timeouts,
status interpretation, JSON serialization and client details are adapter concerns.

## Lifecycle-to-delivery handoff and lost-delivery analysis

For a notification-enabled matching transition, the repository operation commits:

1. lifecycle state version update/insert; and
2. a uniquely identified durable delivery record containing immutable canonical
   transition evidence.

in one local database transaction. A crash before commit persists neither; a crash
after commit leaves both lifecycle and work discoverable. The worker is deliberately
separate and runs only after the transaction. Consequently it never creates lifecycle
transitions and cannot turn M10 into background evaluation.

## Semantics and idempotency

Geordi provides **at-least-once delivery attempts**, not exactly-once network delivery.
If a receiver completes a request but the response is lost, Geordi retries. A stable
delivery ID, deterministic from the immutable canonical policy id, transition type,
and transition occurrence/evidence time (SHA-256 encoded as a fixed safe identifier),
is persisted as the logical identity and sent in the payload/header. Receivers must
deduplicate by it. A unique storage constraint prevents duplicate work from repeated
or concurrent lifecycle processing.

## Storage, processing, concurrency, and restart recovery

Add a Flyway table for delivery records: delivery ID (unique), immutable destination
ID and non-secret endpoint/configuration fingerprint, transition type, canonical payload
JSON, state, attempts, next-attempt time, claim token/lease expiry and completion time.
States are `PENDING`, `LEASED`, `DELIVERED`, and `FAILED`; lifecycle state never
changes when delivery fails. A provider-neutral port accepts the lifecycle decision and
optional delivery candidate, then returns `COMMITTED` (with its delivery ID) or
`CONFLICT`. Its H2 adapter executes conditional lifecycle INSERT/UPDATE and outbox
INSERT in one transaction; conflict or outbox failure rolls both back. HTTP never runs
in that transaction.

Destination IDs are immutable: changing a target requires a new ID. Claimed work
dispatches only when its persisted destination ID/fingerprint matches configured
non-secret material; incompatible work is marked terminally failed, never silently
rerouted.
Disabling delivery preserves pending work but does not claim it; re-enabling resumes
compatible work. Transitions while disabled or unselected create no work and are never
backfilled.

A bounded single-node Spring worker polls at a configured interval, claims at most a
configured batch using compare-and-set/lease semantics, and processes a fixed bounded
number concurrently. Each claim writes a random token and expiry; success, retry and
terminal updates require that token, so a late worker cannot overwrite a reclaimed
claim. Claiming atomically consumes an attempt before HTTP, so a crash after receiver
acceptance cannot bypass the configured maximum. Request timeout is shorter than lease duration. Lease expiry makes interrupted
`LEASED` work recoverable after restart; terminal `DELIVERED` and `FAILED` work is
never claimed. This is tested as a single-node guarantee only—no multi-node claim is
asserted.

## Retry and HTTP failure policy

Defaults are deliberately bounded: batch 10, concurrency 1, polling 1 second,
maximum 3 attempts, and fixed durable delays of 1s then 5s. 2xx is delivered. 4xx
except 429 is terminal failure. 429, 5xx,
connection failures and timeouts are retryable; exhausted work is `FAILED`. No request
thread sleeps for backoff, and durable `next_attempt_at` survives restart.

## Webhook contract and configuration/secrets

The versioned JSON payload includes schema version, delivery ID, transition type,
policy id/name, SLO id, service identity, environment, canonical evidence/evaluation
timestamps and range, condition and relevant investigation context. It contains no
persistence representation, credentials, provider response types or incident fields.

Configuration is deployment-managed YAML/properties: enabled flag, selected canonical
transition types, immutable destination ID, HTTPS endpoint URL, connect/read timeout,
and a secret token sourced only from an environment variable. Enabled configuration
fails closed at startup when any field, bounds, supported transition type, endpoint,
header name, or required secret is invalid/missing. The token is put in a fixed header
by the HTTP adapter; it is never stored, returned by an API, placed in payloads, logs,
traces, or metric labels. Local Compose can explicitly enable a test-only HTTP receiver
with a non-production token; normal and production configuration require HTTPS. HTTP
redirects are not followed; URI user-info is rejected and all error rendering redacts
the URI query and header values.

## Self-observability and health

Use the existing `io.geordi.alerts` meter convention: unlabelled attempts, unexpected
failures and duration; results labelled only with closed delivery outcome and canonical
transition type; a retry counter if retries are implemented. Never label policy/SLO/
delivery IDs, service/environment, URL, HTTP status, exception text, or secrets.

Individual webhook failure is operational delivery state, not platform unhealthiness.
The durable delivery-store probe verifies both lifecycle and outbox schema/read access,
is a required Alerts dependency and makes Alerts and readiness DOWN when unavailable;
it performs no dispatch. Disabled Alerts skips it.

## API and frontend decision

No API or frontend surface is required for reliability and none is added in this
milestone. Delivery state is proven through integration tests and the local semantic
fixture. Read-only inspection can be considered only when an operator need is shown.

## Security and failure handling

HTTPS is mandatory outside the explicit local test receiver; unsafe schemes, user-info,
and redirects are rejected. Secrets and URL query/header values are redacted from
errors. Network ambiguity is documented as at-least-once. Database persistence failure
fails the lifecycle command in a controlled manner: a transition eligible for delivery
is not committed without its durable record.

## Testing and semantic smoke

Unit tests cover stable identity, payload, state transitions, retry classification,
bounded attempts, duplicate claims, and no work without a lifecycle transition.
Repository integration tests prove transactional lifecycle/outbox persistence,
restart discoverability, terminal non-redelivery, and persistence health. HTTP adapter
tests cover 2xx, 4xx, 429, 5xx, timeout/connection failure and redaction. Architecture
tests prohibit framework/HTTP/JDBC/telemetry dependencies in notification domain and
application packages.

`scripts/verify-notification-delivery.ps1` uses a deterministic local receiver and
proves STARTED/RESOLVED, stable identity, no-transition/unavailable absence, retry and
recovery, restart recovery, successful non-redelivery, bounded telemetry and absence
of configured secret material. It is appended after the M10 smoke in GitLab.

## Non-goals

No evaluation scheduler, generic scheduler/broker, email/SMS/Slack/Teams, runtime
notification CRUD, UI, incident acknowledgement/silencing/escalation/on-call, generic
workflow/rules, multi-node guarantee, or M12 work.

## Acceptance criteria

- A committed eligible transition and one durable delivery record commit atomically.
- Every committed record receives at least one attempt while compatible dispatch is
  enabled; delivery success is not guaranteed, retries are bounded, and a
  post-send/pre-ack crash can duplicate receiver calls.
- Delivery state is separate from M10 lifecycle state and terminal rows do not replay.
- One bounded webhook worker recovers durable work across restart.
- Adapter, persistence and telemetry are isolated by ports and ArchUnit rules.
- Tests, local Compose, semantic smoke and documentation prove only delivered scope.

## Rollback, limitations, and deferred debt

The additive migration is retained on rollback; disable delivery to stop dispatch while
preserving pending evidence. H2/leases are a supported single-node local topology, not
distributed worker coordination. Exact-once receiver processing is impossible over
HTTP; receiver-side delivery-ID deduplication is required. Deferred: delivery-status
API/UI, richer routing/adapters, production HA store/coordination, and a configurable
backoff policy.

## Implementation and local validation

Implemented on 2026-08-28 with Flyway V2, atomic lifecycle/outbox persistence,
deterministic SHA-256 delivery IDs, token-guarded leases, bounded durable retries, one
HTTP webhook adapter, deployment validation, low-cardinality telemetry, storage health,
ArchUnit enforcement, and a deterministic local receiver/smoke. No API or frontend was
added. Java 21 Docker verification passed 231 tests plus PMD, SpotBugs, Find Security
Bugs, and ArchUnit. Compose validation and the M1–M10 semantic regression chain passed;
the M11 smoke passed STARTED/RESOLVED delivery, stable identity, retry, restart recovery,
terminal non-redelivery, bounded telemetry, and secret isolation. Authoritative GitLab
revalidation remains required before COMPLETE.
