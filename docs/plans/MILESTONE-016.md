# Milestone 016 — Episode-Scoped Alert Acknowledgement Foundation

Status: M16 IMPLEMENTED — LOCAL VALIDATION IN PROGRESS

## Owner-approved scope

M16 adds one immutable acknowledgement fact to one durable M14 alert episode.
It does not change alert evaluation, lifecycle state, delivery, scheduling,
routing, or canonical transition history.

M10 remains authoritative for current `INACTIVE`/`FIRING` state. M14 remains
authoritative for canonical `STARTED`/`RESOLVED` episode history. M15 remains the
read-only episode investigation workflow, extended only with an episode-detail
acknowledgement action.

## Domain contract

An acknowledgement is an immutable row identified by `episodeId`. There is at
most one acknowledgement per episode. Row existence is the state; M16 does not
introduce `ACKNOWLEDGED`/`NOT_ACKNOWLEDGED` enums, unacknowledge, retrospective
acknowledgement, comments, assignment, or a generic operator-action ledger.

The domain value is:

```text
AlertEpisodeAcknowledgement
- episodeId
- actor
- reason
- acknowledgedAt
```

`actor` is required, trimmed, 1–128 Unicode characters, case-preserving, and
opaque. It is caller-asserted and spoofable: Geordi currently has no authenticated
operator identity or RBAC. It must never be described as authenticated or
audit-grade identity.

`reason` is optional. It is trimmed; blank-after-trim becomes `null`; maximum
length is 512 Unicode characters.

`acknowledgedAt` is generated only by the server from the injected `Clock` and is
never accepted from the request.

## Command semantics

```http
POST /api/alert-episodes/{episodeId}/acknowledgements
Content-Type: application/json

{"actor":"operator@example","reason":"Investigating elevated errors"}
```

Responses:

| Situation | Result |
| --- | --- |
| Open episode, no acknowledgement | `201 Created` with the new fact |
| Same normalized actor and reason | `200 OK` with the original fact and original `acknowledgedAt` |
| Different normalized actor or reason | `409 Conflict`; never overwrite |
| Closed normal episode | `409 Conflict` |
| Closed legacy episode | `409 Conflict` |
| Missing episode | `404 Not Found` |
| Invalid actor or reason | `400 Bad Request` |
| Persistence failure | `503 Service Unavailable` |

No retrospective acknowledgement and no `UNACKNOWLEDGE` are included in M16.
Exact replay compares the normalized values stored by the first command.

## Read contract

Only episode detail exposes acknowledgement. Episode list responses do not gain
an acknowledgement field or badge in M16.

Unacknowledged detail:

```json
"acknowledgement": null
```

Acknowledged detail:

```json
"acknowledgement": {
  "actor": "operator@example",
  "reason": null,
  "acknowledgedAt": "2026-09-08T12:00:00.123456789Z"
}
```

The API must not expose a separate acknowledgement state enum unless later
repository evidence demonstrates a real need.

## Aggregate and transaction boundary

Acknowledgement belongs to the concrete M14 episode, not to M10 lifecycle state
and not to a general operator-action aggregate. It therefore cannot carry into a
later episode for the same policy.

ACK and canonical M14 resolution must share an explicit episode-row serialization
boundary using the existing H2 transaction boundary:

1. ACK selects the episode by ID `FOR UPDATE`.
2. Missing row returns `404`.
3. A non-null `closed_at` returns `409`.
4. Existing acknowledgement is compared: exact replay returns `200`; a conflict returns `409`.
5. Otherwise the row is inserted and committed.
6. Canonical resolution selects the open episode `FOR UPDATE` before closing it.

Required race behavior:

- ACK commits first: acknowledgement persists; resolution subsequently closes the episode normally.
- RESOLVE commits first: ACK observes `closed_at`, returns `409`, and inserts nothing.

This strengthens the concurrent command boundary without changing M14’s domain
semantics, transition identity, or lifecycle authority.

Concurrent duplicate ACKs are serialized by the row lock and protected by the
primary-key uniqueness constraint. The winning row is reread for exact replay or
conflict.

## Persistence and migration

Use the existing H2 datasource and add only:

```text
V5__create_alert_episode_acknowledgement.sql
```

```text
alert_episode_acknowledgement
- episode_id       VARCHAR(64) PRIMARY KEY REFERENCES alert_episode(episode_id)
- actor            VARCHAR(128) NOT NULL
- reason           VARCHAR(512)
- acknowledged_at  TIMESTAMP(9) WITH TIME ZONE NOT NULL
```

The foreign key has no cascade. There is no backfill, no new database, and no
rewrite of V1–V4. Existing open M14 episodes are eligible; closed and legacy
episodes are rejected by application semantics. Alerts persistence health must
include this table.

## Existing milestone boundaries preserved

ACK must not:

- invoke or alter M9 evaluation;
- change M10 lifecycle state or fabricate transitions;
- create, cancel, modify, or suppress M11 delivery work;
- affect M12 scheduling;
- rerun or alter M13 routing;
- alter canonical M14 `STARTED`/`RESOLVED` history.

Acknowledgement-aware delivery is explicitly deferred.

## UI scope

The action appears only in open episode detail. It accepts caller-supplied actor
and optional reason, disables while pending, refreshes after success, and keeps
the existing bookmark/detail workflow.

On either ACK/RESOLVE `409`, the UI must refetch episode detail so it cannot
continue presenting stale `OPEN` state. Actor and reason are rendered as escaped
text. No list acknowledgement indicator is added.

## Observability, security, and privacy

Add low-cardinality acknowledgement outcome telemetry using fixed outcomes such
as `created`, `duplicate`, `conflict`, `invalid`, `not_found`, and `failure`.
Never label or log actor, reason, episode ID, policy ID, service identity, or
arbitrary exception text. Bounded validation and escaped rendering are required.

The caller-supplied actor limitation must be visible in API and operator
documentation. M16 does not introduce authentication, RBAC, SSO, or a security
claim beyond input validation and bounded persistence.

## Testing and semantic smoke

RED-first tests must cover open ACK, exact replay, conflicting replay, closed and
legacy episodes, missing episodes, actor/reason normalization and bounds,
server-generated timestamps, FK/uniqueness/rollback/restart/migration, both
ACK/RESOLVE commit orders, concurrent duplicate ACK, nullable detail JSON, RFC9457
errors, safe UI rendering, pending state, refresh after `409`, and absence of
M9–M13 side effects.

The semantic smoke reuses the M14 fixture: create a real episode, ACK it through
the public API/proxy, verify detail and exact replay, restart, resolve, verify
unchanged canonical history and no extra M11/M13 activity, then reject ACK after
closure.

## Non-goals

Comments, ownership, incidents, silences, maintenance windows, escalation,
notification cancellation, retry redesign, generic activity feeds, auth/RBAC
redesign, HA, retention deletion, fan-out, policy CRUD, and M17 are excluded.

No M17 is pre-committed. After M16 closure, the next milestone must be
investigated again. Acknowledgement-aware delivery remains only a candidate.

## Independent review

The configured fresh reviewer dispatch was attempted twice and rejected by the
Codex task-creation capability before a reviewer task started. Consequently no
independent reviewer result is claimed here. A local read-only audit found no
known BLOCKER/HIGH, but this is not a substitute for the required independent
review. Implementation planning must remain gated on a successful fresh review
covering locking/order, both race outcomes, duplicate ACK, migration constraints,
nullable detail contract, actor spoofability, leakage, M11/M13 isolation, and
scope drift.

## Verification status

This reconciliation is documentation-only. Production code was not modified.
The implementation gates remain pending: backend/frontend tests, migration
upgrade tests, semantic smoke, full quality gates, and independent review.

## Implementation plan

This plan is RED-first and preserves the existing hexagonal boundary. Transaction
mechanics remain in the H2 adapter; no JDBC, H2, `FOR UPDATE`, or Spring
transaction type enters the domain or application model.

### 1. Domain and application sequence

Add:

- `domain/AlertEpisodeAcknowledgement` with constructor validation and normalized values;
- `application/AcknowledgeAlertEpisodeUseCase`;
- `application/AcknowledgeAlertEpisodeService`;
- `application/AcknowledgeAlertEpisodeResult` with `CREATED`, `REPLAYED`, and `CONFLICT`;
- bounded application exceptions for missing, closed, conflicting, invalid, and persistence outcomes;
- an output-port acknowledgement command/result DTO as repository conventions dictate.

Extend:

- `AlertEpisodeDetail` with nullable acknowledgement;
- `AlertHistoryQueryService` to load the acknowledgement for detail only;
- `AlertsModuleConfiguration` to wire the use case and observed repository;
- `AlertHistoryExceptionHandler` for RFC9457 `400`, `404`, `409`, and `503` mappings.

Normalization is performed once at the application/domain boundary: `String.strip()`;
actor is required and measured with `codePointCount(0, length)` in 1–128; reason is
optional, blank after strip becomes null, and is measured in 0–512 code points.
No NFC/NFKC normalization is introduced. Server time comes only from the injected
`Clock`.

### 2. Ports and atomic repository seam

Add a narrow operation to the persistence boundary, conceptually:

```text
acknowledgeEpisode(episodeId, normalizedActor, normalizedReason, acknowledgedAt)
```

It returns a bounded result containing `CREATED`, `REPLAYED`, or `CONFLICT` and the
existing fact where applicable. The application must not compose find/inspect/insert
calls.

Add a private persistence seam used only inside `AlertLifecycleRepository.commit(...)`
for canonical resolution to lock the open episode row. Do not expose a public
`selectForUpdate` port and do not wrap M14 commit in a second transaction.

### 3. H2 implementation and ordering

In `H2AlertLifecycleRepository`, add:

```sql
SELECT episode_id, policy_id, opened_at, closed_at, origin
FROM alert_episode
WHERE episode_id = ?
FOR UPDATE
```

for ACK, and an equivalent open-episode-by-policy `FOR UPDATE` query for M14
resolution. The ACK operation executes under the existing `TransactionTemplate`:

```text
BEGIN
  SELECT episode ... FOR UPDATE
  missing -> not found
  closed_at != null -> closed conflict
  SELECT acknowledgement by episode_id
  exact normalized actor/reason -> replay
  different values -> conflict
  INSERT acknowledgement
COMMIT
```

M14 resolution locks the episode after the lifecycle CAS has won but before the
episode close/history mutation is applied, inside the existing repository commit
transaction. Preserve rollback of lifecycle, episode, history, and matched outbox
work as one unit.

Lock timeout, deadlock, and transaction failures map to persistence/unavailable
behavior. They must never be interpreted as a successful ACK or allow ACK after
resolution.

Update `ObservedAlertHistoryRepository` or introduce the smallest corresponding
observed acknowledgement decorator so fixed outcome telemetry is emitted at the
repository boundary without actor/reason attributes.

### 4. RED-first implementation order

1. Add domain tests for normalization, Unicode code-point bounds, immutable fact,
   and server timestamp ownership.
2. Add application tests for created, exact replay, conflicting replay, missing,
   closed, legacy, rollback, and no-side-effect behavior.
3. Add the V5 migration and persistence tests.
4. Add repository race tests with ACK-wins and RESOLVE-wins ordering plus concurrent
   duplicate ACK.
5. Add application/controller tests for result-to-HTTP mapping.
6. Extend detail query and backend response tests.
7. Add frontend API/client, hook, component, and page tests before UI code.
8. Add the semantic smoke assertions.
9. Update OpenAPI and documentation.
10. Run closure gates and independent implementation review.

### 5. Migration and migration tests

Create `backend/src/main/resources/db/migration/V5__create_alert_episode_acknowledgement.sql`:

```sql
CREATE TABLE alert_episode_acknowledgement (
    episode_id VARCHAR(64) PRIMARY KEY,
    actor VARCHAR(128) NOT NULL,
    reason VARCHAR(512),
    acknowledged_at TIMESTAMP(9) WITH TIME ZONE NOT NULL,
    CONSTRAINT alert_episode_acknowledgement_episode_fk
        FOREIGN KEY (episode_id) REFERENCES alert_episode (episode_id)
);
```

No cascade and no backfill. Extend the existing migration integration style with:

- clean V1–V5 install;
- V4 → V5 upgrade;
- preservation of existing open and closed episodes;
- FK and one-row-per-episode constraints;
- nanosecond acknowledgement timestamp round-trip.

### 6. Exact expected file inventory

Expected backend additions/modifications:

- `backend/src/main/resources/db/migration/V5__create_alert_episode_acknowledgement.sql`;
- `backend/src/main/java/io/geordi/alerts/domain/AlertEpisodeAcknowledgement.java`;
- acknowledgement application use case, service, result, exceptions, and port files;
- `AlertEpisodeDetail.java`, `AlertHistoryQueryService.java`;
- `AlertLifecycleRepository.java` and `H2AlertLifecycleRepository.java`;
- `ObservedAlertHistoryRepository.java` or a focused acknowledgement observer;
- `AlertsModuleConfiguration.java`;
- `AlertHistoryController.java` and `AlertHistoryExceptionHandler.java`;
- focused domain/application/controller/persistence/migration tests;
- `AlertsModuleConfigurationTest.java` and persistence health tests where required.

Expected frontend additions/modifications:

- `frontend/src/api/alertHistory.ts` and its tests;
- `frontend/src/features/alert-history/useAlertHistory.ts`;
- `AlertEpisodeDetail.tsx`, `AlertHistoryPage.tsx`, presentation tests, and page tests;
- scoped styles only if needed for the form and status announcement.

Expected operational/documentation files:

- `scripts/verify-alert-history.ps1`;
- `docs/api/openapi.yaml`;
- `docs/architecture/ALERT_LIFECYCLE.md`;
- `docs/architecture/NOTIFICATION_DELIVERY.md` only to state that ACK has no delivery effect;
- `docs/product/PRD.md`, `docs/product/ROADMAP.md`, and `README.md`;
- `.gitlab-ci.yml` only if existing smoke wiring requires an explicit change.

### 7. REST and detail contract tests

Add `POST /api/alert-episodes/{episodeId}/acknowledgements` tests for `201`, exact
`200`, invalid `400`, missing `404`, closed/conflicting `409`, persistence `503`,
RFC9457 media type, and absence of client-controlled `acknowledgedAt`.

Extend episode detail tests to assert `acknowledgement: null` and the object form.
Do not change episode list schemas or list response fixtures.

### 8. Frontend plan

Add a mutation client and hook keyed by episode ID. The detail component renders an
open-episode-only form with required actor and optional reason, client-side bounds,
pending/disabled state, accessible status/error messaging, and safe text rendering.

On `201` or `200`, invalidate/refetch the episode-detail query. On `409`, refetch
before presenting the error so a concurrent RESOLVE cannot leave stale OPEN UI.
Preserve the selected episode URL bookmark and do not add list badges or state.

### 9. Semantic smoke extension

Reuse `scripts/verify-alert-history.ps1` and the existing M14 fixture. Add assertions
for START → ACK → exact replay → backend restart → durable ACK → RESOLVE → unchanged
canonical history except the legitimate RESOLVED transition → post-close ACK `409`.
Inspect durable rows to prove one acknowledgement, no new routing/outbox/delivery,
bounded actor/reason persistence, and no actor/reason telemetry labels.

### 10. OpenAPI and documentation impact

Add the POST operation, request/response schemas, nullable detail field, and RFC9457
responses to `docs/api/openapi.yaml`. Document caller-asserted spoofable actor
semantics, server timestamp ownership, exact replay, closed-episode behavior, and
the absence of delivery effects. Keep M17 and all existing non-goals unchanged.

### 11. Local closure gates

Run, in order:

1. `git diff --check` and migration/schema review;
2. backend `./mvnw -B -ntp verify`;
3. frontend `npm ci`, `npm test`, `npm run typecheck`, `npm run lint`, `npm run build`;
4. Compose configuration validation;
5. existing M9 → M15 semantic chain, with the extended alert-history smoke;
6. restart, migration-upgrade, race, rollback, and persistence-health tests;
7. final diff and documentation synchronization review.

The implementation is not complete until the independent implementation review
reports **BLOCKER 0 / HIGH 0**, all required gates pass, and no production behavior
outside M16 changes.
